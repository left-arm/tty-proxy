const std = @import("std");
const posix = std.posix;

const config = @import("config.zig");
const StartupEncoder = @import("startup.zig").StartupEncoder;

const c = std.c;

extern "c" fn cfmakeraw(term: *c.termios) void;
extern "c" fn tty_proxy_fd_zero(set: *anyopaque) void;
extern "c" fn tty_proxy_fd_in_range(fd: c_int) c_int;
extern "c" fn tty_proxy_fd_set(fd: c_int, set: *anyopaque) void;
extern "c" fn tty_proxy_fd_isset(fd: c_int, set: *const anyopaque) c_int;
extern "c" fn tty_proxy_pselect(
    nfds: c_int,
    readfds: *anyopaque,
    writefds: *anyopaque,
    exceptfds: *anyopaque,
    timeout: ?*const c.timespec,
    mask: *const c.sigset_t,
) c_int;

// compat.c checks that fd_set fits this storage and alignment.
const FdSet = extern struct {
    storage: [128]u8 align(8) = undefined,

    fn init() FdSet {
        var self = FdSet{};
        tty_proxy_fd_zero(&self);
        return self;
    }

    fn set(self: *FdSet, fd: c.fd_t) void {
        tty_proxy_fd_set(fd, self);
    }

    fn isSet(self: *const FdSet, fd: c.fd_t) bool {
        return tty_proxy_fd_isset(fd, self) != 0;
    }
};

// Shared fixed-size buffer capacity used for both directions of the proxy.
// Startup metadata is generated incrementally through the same outbound buffer.
const BUFFER_SIZE: usize = 16 * 1024;

// Reserve read capacity, not input bytes: a lone Escape is still read at once.
const STDIN_READ_HEADROOM: usize = 256;

// Limit read syscalls per turn so busy stdin cannot starve peer I/O or signals.
const STDIN_READ_LIMIT: usize = 8;

// Handlers only record cancellation. Signals are blocked outside pselect.
var terminate_signal = std.atomic.Value(i32).init(0);

var termination_count = std.atomic.Value(u32).init(0);
var last_termination_signal = std.atomic.Value(i32).init(0);

// High-level process exit reasons used by main() to select the final exit code.
const RunOutcome = union(enum) {
    connection_closed,
    error_mode_complete,
    signaled: i32,
    completed: u8,
};

// The peer chooses the terminal behavior by sending one leading mode byte. R
// asks tty-proxy to enable raw mode and restore the previous settings on exit;
// C and E leave settings unchanged; D delegates tty I/O to the peer and
// restores the pre-startup snapshot on exit.
const OperationMode = enum {
    none,
    raw,
    canonical,
    direct,
    err,

    // Terminal input is only meaningful once the peer has chosen an interactive
    // mode. In .none we are still waiting for the initial mode byte; in .err we
    // intentionally stop forwarding stdin. The .canonical variant means
    // "leave stdin's termios state as-is," not "force canonical mode."
    fn canReadStdin(self: OperationMode) bool {
        return self == .raw or self == .canonical;
    }

    // Startup bytes must still be writable while in .none, so only .err blocks
    // further peer writes.
    fn canWritePeer(self: OperationMode) bool {
        return self != .err;
    }
};

// After D, the peer may send one unsigned status byte, then EOF.
// EOF completes the session; an omitted status defaults to zero.
// No terminal input is forwarded in D mode. Write-side EOF requests detachment.
const DirectSession = struct {
    status: ?u8 = null,

    fn receive(self: *DirectSession, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.status != null or bytes.len > 1) return error.TooManyExitStatusBytes;
        self.status = bytes[0];
    }

    fn exitStatus(self: *const DirectSession) u8 {
        return self.status orelse 0;
    }
};

// A compact single-producer/single-consumer byte buffer used for both directions
// of the proxy. It compacts in-place when contiguous write space is too small.
const Buffer = struct {
    data: [BUFFER_SIZE]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn canRead(self: *const Buffer) bool {
        return self.start < self.end;
    }

    fn ensureWriteSpace(self: *Buffer, minimum: usize) void {
        std.debug.assert(minimum > 0 and minimum <= self.data.len);
        // Avoid copying when even compaction cannot provide enough capacity.
        if (self.data.len - self.end < minimum and
            self.start > 0 and self.data.len - (self.end - self.start) >= minimum)
        {
            const remaining = self.end - self.start;
            std.mem.copyForwards(
                u8,
                self.data[0..remaining],
                self.data[self.start..self.end],
            );
            self.start = 0;
            self.end = remaining;
        }
    }

    fn canWriteAtLeast(self: *Buffer, minimum: usize) bool {
        self.ensureWriteSpace(minimum);
        return self.data.len - self.end >= minimum;
    }

    fn canWrite(self: *Buffer) bool {
        return self.canWriteAtLeast(1);
    }

    fn writeSlice(self: *Buffer) []u8 {
        self.ensureWriteSpace(1);
        return self.data[self.end..];
    }

    fn readSlice(self: *const Buffer) []const u8 {
        return self.data[self.start..self.end];
    }

    fn produce(self: *Buffer, count: usize) void {
        self.end += count;
    }

    fn consume(self: *Buffer, count: usize) void {
        self.start += count;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
    }
};

// Zero bytes does not mean EOF. A batch can read bytes and then reach EOF.
const TerminalReadResult = struct {
    bytes: usize = 0,
    eof: bool = false,
};

// Batch available terminal input before the next socket write. A short tty read
// need not drain all available bytes; retrying can reduce proxy-induced gaps
// between fragments of an already available key sequence.
fn readTerminalInput(fd: c.fd_t, buffer: *Buffer) !TerminalReadResult {
    var result = TerminalReadResult{};

    for (0..STDIN_READ_LIMIT) |_| {
        if (!buffer.canWriteAtLeast(STDIN_READ_HEADROOM)) break;

        const chunk = buffer.writeSlice();
        const rc = c.read(fd, chunk.ptr, chunk.len);

        if (rc == 0) {
            result.eof = true;
            break;
        } else if (rc > 0) {
            const count: usize = @intCast(rc);
            buffer.produce(count);
            result.bytes += count;
        } else switch (c.errno(rc)) {
            .INTR, .AGAIN => break,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    return result;
}

fn getFdFlags(fd: c.fd_t) !c.O {
    while (true) {
        const rc = c.fcntl(fd, c.F.GETFL);
        if (rc >= 0) return @bitCast(rc);
        switch (c.errno(rc)) {
            .BADF => return error.InvalidFileDescriptor,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setFdFlags(fd: c.fd_t, flags: c.O) !void {
    while (true) {
        const rc = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(flags)));
        switch (c.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

// Snapshot every descriptor before changing any flags: standard descriptors
// may share an open-file description, so changing one can change the others.
const StdioFlagsGuard = struct {
    fds: [3]c.fd_t,
    original: [3]c.O,

    fn capture(fds: [3]c.fd_t) !StdioFlagsGuard {
        var guard = StdioFlagsGuard{ .fds = fds, .original = undefined };
        for (fds, 0..) |fd, i| {
            guard.original[i] = try getFdFlags(fd);
        }
        return guard;
    }

    fn enableNonBlocking(self: *const StdioFlagsGuard) !void {
        for (self.fds, self.original) |fd, original| {
            var flags = original;
            flags.NONBLOCK = true;
            try setFdFlags(fd, flags);
        }
    }

    fn restore(self: *const StdioFlagsGuard) void {
        // Restore all descriptors even if an individual restoration fails.
        for (self.fds, self.original) |fd, flags| {
            setFdFlags(fd, flags) catch {};
        }
    }
};

// Snapshot before startup; only R and D own final restoration.
const TerminalGuard = struct {
    fd: c.fd_t,
    original: c.termios,

    fn capture(fd: c.fd_t) !TerminalGuard {
        var current: c.termios = undefined;

        while (true) {
            const rc = c.tcgetattr(fd, &current);
            switch (c.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        return .{ .fd = fd, .original = current };
    }

    fn enableRaw(self: *const TerminalGuard) !void {
        var current = self.original;

        cfmakeraw(&current);

        while (true) {
            const rc = c.tcsetattr(self.fd, c.TCSA.NOW, &current);
            switch (c.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    fn restore(self: *TerminalGuard) void {
        // A shell may have reclaimed the foreground after suspending this
        // job. Cleanup must not stop on SIGTTOU before restoring shared state.
        var signals = posix.sigemptyset();
        posix.sigaddset(&signals, c.SIG.TTOU);
        var previous_mask: c.sigset_t = undefined;
        if (c.sigprocmask(c.SIG.BLOCK, &signals, &previous_mask) < 0) return;
        defer _ = c.sigprocmask(c.SIG.SETMASK, &previous_mask, null);

        while (true) {
            const rc = c.tcsetattr(self.fd, c.TCSA.NOW, &self.original);
            switch (c.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => return,
            }
        }
    }
};

// Buffered terminal -> peer bytes.
var to_lisp = Buffer{};

// Buffered peer -> terminal bytes.
var to_term = Buffer{};

// Translates the peer's single-byte mode protocol into an enum used by the
// rest of the runtime.
fn parseMode(byte: u8) !OperationMode {
    return switch (byte) {
        'R' => .raw,
        'C' => .canonical,
        'E' => .err,
        'D' => .direct,
        else => return error.InvalidMode,
    };
}

// Read the standard clock without the full process.Init runtime or threads.
var clock_io: std.Io.Threaded = .init_single_threaded;

fn monotonicNow() std.Io.Timestamp {
    return std.Io.Clock.awake.now(clock_io.io());
}

fn connectUnixSocket(path: []const u8) !c.fd_t {
    var address: c.sockaddr.un = std.mem.zeroes(c.sockaddr.un);
    if (path.len >= address.path.len) return error.NameTooLong;
    address.family = c.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    if (@hasField(c.sockaddr.un, "len")) address.len = @intCast(address_len);

    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return posix.unexpectedErrno(c.errno(fd));
    errdefer _ = c.close(fd);
    const rc = c.connect(fd, @ptrCast(&address), address_len);
    if (rc != 0) return posix.unexpectedErrno(c.errno(rc));
    return fd;
}

// All pumped I/O is driven from pselect(), so participating descriptors use
// nonblocking mode. Direct mode leaves stdio flags unchanged.
fn setNonBlocking(fd: c.fd_t) !void {
    var flags = try getFdFlags(fd);
    flags.NONBLOCK = true;
    try setFdFlags(fd, flags);
}

fn closeWriteSide(fd: c.fd_t) !void {
    while (true) {
        const rc = c.shutdown(fd, 1);
        switch (c.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

// Block the signals checked by the event loop, and return a mask that
// temporarily unblocks them during pselect().
fn blockTerminationSignals() !c.sigset_t {
    var signals = posix.sigemptyset();
    inline for (.{ c.SIG.INT, c.SIG.TERM, c.SIG.HUP }) |signal| {
        posix.sigaddset(&signals, signal);
    }

    // Block these signals and save the previous mask in one call.
    var wait_mask: c.sigset_t = undefined;
    const rc = c.sigprocmask(c.SIG.BLOCK, &signals, &wait_mask);
    if (rc < 0) return posix.unexpectedErrno(c.errno(rc));

    inline for (.{ c.SIG.INT, c.SIG.TERM, c.SIG.HUP }) |signal| {
        posix.sigdelset(&wait_mask, signal);
    }

    return wait_mask;
}

fn signalHandler(signal: c.SIG) callconv(.c) void {
    const signal_int: i32 = @intCast(@backingInt(signal));
    last_termination_signal.store(signal_int, .monotonic);
    _ = termination_count.fetchAdd(1, .monotonic);
    _ = terminate_signal.cmpxchgStrong(0, signal_int, .monotonic, .monotonic);
}

// Handlers record cancellation only; half-close and cleanup run in the loop.
fn installSignalHandlers() void {
    const action = c.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(c.SIG.INT, &action, null);
    posix.sigaction(c.SIG.TERM, &action, null);
    posix.sigaction(c.SIG.HUP, &action, null);

    // Let write() report EPIPE instead of terminating the process, so the
    // normal error path can run and restore terminal settings.
    const ignore_pipe = c.Sigaction{
        .handler = .{ .handler = @ptrFromInt(1) },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(c.SIG.PIPE, &ignore_pipe, null);
}

fn isCancelled() bool {
    return terminate_signal.load(.monotonic) != 0;
}

// Runtime contract: tty-proxy is expected to be launched by a user
// from a shell in a terminal, with normal shell terminal settings.
//
// Unusual terminal configurations (e.g. noncanonical polling with
// VMIN=0) are out of scope. A zero-byte tty read is treated as EOF.
//
// Owns startup, the readiness loop, and shutdown/drain behavior.
fn run(init: std.process.Init.Minimal) !RunOutcome {
    // Leave default signal actions active during potentially blocking startup.
    // No shared fd flags or terminal settings have been changed yet.
    if (c.isatty(c.STDIN_FILENO) == 0) {
        return error.StdinIsNotATerminal;
    }

    // Validate and snapshot stdio before opening config files or sockets.
    // Otherwise a closed stdout/stderr could be reused as the peer socket,
    // making terminal output feed back into the protocol instead of failing.
    const stdio_flags = try StdioFlagsGuard.capture(.{
        c.STDIN_FILENO,
        c.STDOUT_FILENO,
        c.STDERR_FILENO,
    });

    const allocator = std.heap.c_allocator;

    const socket_path = try config.resolveSocket(
        init.environ,
        allocator,
        std.mem.sliceTo(init.args.vector[0], 0),
    );
    defer allocator.free(socket_path);

    const peer_fd = try connectUnixSocket(socket_path);
    defer _ = c.close(peer_fd);
    // Stdio uses fixed descriptors 0–2; only the peer needs a bounds check.
    if (tty_proxy_fd_in_range(peer_fd) == 0) return error.FileDescriptorOutOfRange;

    // From here on, termination must run cleanup. Keep signals blocked except
    // during pselect() to avoid a race between checking the flag and sleeping.
    const wait_signal_mask = try blockTerminationSignals();
    installSignalHandlers();

    var stdio_changed = false;
    defer if (stdio_changed) stdio_flags.restore();

    var terminal = try TerminalGuard.capture(c.STDIN_FILENO);
    var restore_terminal = false;
    defer if (restore_terminal) terminal.restore();

    // Make the peer socket nonblocking now. Stdio changes only after R/C/E
    // selection; D leaves its flags alone.
    try setNonBlocking(peer_fd);

    // stdin EOF: stop reading terminal input
    var term_open = true;

    // peer EOF: stop reading peer input, but keep draining buffered output
    var peer_open = true;

    // Capture terminal metadata now, then encode incrementally in the loop.
    var startup = try StartupEncoder.init(c.STDIN_FILENO, init.args.vector, init.environ.block.slice);
    var startup_complete = false;

    var mode: OperationMode = .none;
    var direct = DirectSession{};
    var shutdown_deadline: ?std.Io.Timestamp = null;

    while (true) {
        if (mode == .direct) {
            const cancellations = termination_count.load(.monotonic);
            if (cancellations > 0) {
                if (shutdown_deadline == null) {
                    // EOF requests detachment of this session, not termination
                    // of the long-lived peer. Stop even an early D's startup.
                    try closeWriteSide(peer_fd);
                    to_lisp.consume(to_lisp.readSlice().len);
                    shutdown_deadline = monotonicNow().addDuration(.fromSeconds(2));
                }
                const now = monotonicNow();
                if (cancellations > 1 or now.compare(.gte, shutdown_deadline.?)) {
                    return .{ .signaled = last_termination_signal.load(.monotonic) };
                }
            }
        } else if (isCancelled()) {
            return .{ .signaled = terminate_signal.load(.monotonic) };
        }

        if (peer_open and mode.canWritePeer() and shutdown_deadline == null and !startup.done()) {
            const count = startup.encode(to_lisp.writeSlice());
            to_lisp.produce(count);
        }

        // Latch completion only after all startup bytes have reached the peer.
        // Early R/C must not interleave terminal input with metadata.
        if (!startup_complete and startup.done() and !to_lisp.canRead()) {
            startup_complete = true;
        }

        const output_fd: c.fd_t = if (mode == .err)
            c.STDERR_FILENO
        else
            c.STDOUT_FILENO;

        var read_fds = FdSet.init();
        var write_fds = FdSet.init();
        var except_fds = FdSet.init();

        if (peer_open) {
            // Interactive input starts only after startup has fully drained
            // and the peer has selected C or R mode.
            if (startup_complete and mode.canReadStdin() and term_open and
                to_lisp.canWriteAtLeast(STDIN_READ_HEADROOM))
            {
                read_fds.set(c.STDIN_FILENO);
                except_fds.set(c.STDIN_FILENO);
            }

            // D uses the free to_term storage as a control-read scratch buffer;
            // other modes queue the bytes for stdout/stderr.
            if (to_term.canWrite()) {
                read_fds.set(peer_fd);
                except_fds.set(peer_fd);
            }

            // After the peer selects E mode, do not send any more buffered bytes back.
            if (mode.canWritePeer() and shutdown_deadline == null and to_lisp.canRead()) {
                write_fds.set(peer_fd);
                except_fds.set(peer_fd);
            }
        }

        if (to_term.canRead()) {
            write_fds.set(output_fd);
            except_fds.set(output_fd);
        }

        // Build readiness each iteration from current buffers/state, then wait
        // until one side can make progress.
        var timeout: c.timespec = undefined;
        const timeout_ptr: ?*const c.timespec = if (shutdown_deadline) |deadline| blk: {
            const remaining = @max(monotonicNow().durationTo(deadline).nanoseconds, 0);
            timeout = .{
                .sec = @intCast(remaining / std.time.ns_per_s),
                .nsec = @intCast(remaining % std.time.ns_per_s),
            };
            break :blk &timeout;
        } else null;

        const select_result = tty_proxy_pselect(
            peer_fd + 1,
            &read_fds,
            &write_fds,
            &except_fds,
            timeout_ptr,
            &wait_signal_mask,
        );

        if (select_result < 0) {
            switch (c.errno(select_result)) {
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        // Recompute readiness from the fd_sets returned by pselect().
        const term_in_ready = read_fds.isSet(c.STDIN_FILENO) or
            except_fds.isSet(c.STDIN_FILENO);
        const lisp_in_ready = read_fds.isSet(peer_fd) or except_fds.isSet(peer_fd);
        const lisp_out_ready = write_fds.isSet(peer_fd);
        const term_out_ready = write_fds.isSet(output_fd);

        var stdin_bytes_read: usize = 0;

        if (term_in_ready) {
            const result = try readTerminalInput(c.STDIN_FILENO, &to_lisp);
            stdin_bytes_read = result.bytes;
            if (result.eof) term_open = false;
        }

        if (lisp_in_ready) {
            // The first byte received from the peer is the mode selector. Any
            // remaining bytes are terminal payload or D's optional status.
            var lisp_slice = to_term.writeSlice();
            const read_rc = c.read(
                peer_fd,
                lisp_slice.ptr,
                lisp_slice.len,
            );
            if (read_rc == 0) {
                if (mode == .direct) {
                    return if (isCancelled())
                        .{ .signaled = terminate_signal.load(.monotonic) }
                    else
                        .{ .completed = direct.exitStatus() };
                }
                peer_open = false;
            } else if (read_rc > 0) {
                var count: usize = @intCast(read_rc);

                if (mode == .none) {
                    // The first byte is control data, not payload.
                    mode = try parseMode(lisp_slice[0]);
                    if (mode == .raw or mode == .direct) restore_terminal = true;
                    if (mode == .raw) try terminal.enableRaw();
                    if (mode != .direct) {
                        stdio_changed = true;
                        try stdio_flags.enableNonBlocking();
                    }

                    count -= 1;
                    if (count > 0) {
                        std.mem.copyForwards(
                            u8,
                            lisp_slice[0..count],
                            lisp_slice[1 .. count + 1],
                        );
                    }
                }

                if (mode == .direct) {
                    try direct.receive(lisp_slice[0..count]);
                } else {
                    to_term.produce(count);
                }
            } else switch (c.errno(read_rc)) {
                .INTR, .AGAIN => {},
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        if (peer_open and mode.canWritePeer() and shutdown_deadline == null and to_lisp.canRead() and
            (lisp_out_ready or stdin_bytes_read > 0))
        {
            // Newly read stdin is tried immediately, without another pselect.
            // A partial write/EAGAIN leaves bytes queued for write readiness.
            // Peer EOF or E mode observed above still prevents this write.
            const chunk = to_lisp.readSlice();
            const write_rc = c.write(peer_fd, chunk.ptr, chunk.len);
            if (write_rc < 0) switch (c.errno(write_rc)) {
                .INTR, .AGAIN => {},
                else => |err| return posix.unexpectedErrno(err),
            } else if (write_rc > 0) {
                const written: usize = @intCast(write_rc);
                to_lisp.consume(written);
            }
        }

        if ((startup_complete and !term_open and !to_lisp.canRead()) or mode == .err) {
            _ = c.shutdown(peer_fd, 1);
        }

        if (term_out_ready) {
            // Drain buffered peer output to the selected terminal stream.
            const chunk = to_term.readSlice();
            const write_rc = c.write(output_fd, chunk.ptr, chunk.len);
            if (write_rc < 0) switch (c.errno(write_rc)) {
                .INTR, .AGAIN => {},
                else => |err| return posix.unexpectedErrno(err),
            } else if (write_rc > 0) {
                const written: usize = @intCast(write_rc);
                to_term.consume(written);
            }
        }

        // Exit after peer EOF once buffered output has been fully written.
        if (!peer_open and !to_term.canRead()) {
            return if (mode == .err) .error_mode_complete else .connection_closed;
        }
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    // Non-signal runtime failures are reported as a generic exit status 1.
    const outcome = run(init) catch {
        std.process.exit(1);
    };

    switch (outcome) {
        .connection_closed => {},
        .error_mode_complete => std.process.exit(1),
        .signaled => |signal| std.process.exit(@intCast(128 + signal)),
        .completed => |status| std.process.exit(status),
    }
}

test "fd flags report invalid descriptors without unexpected errno diagnostics" {
    try std.testing.expectError(error.InvalidFileDescriptor, getFdFlags(-1));
}

test "terminal restoration preserves the signal mask on failure" {
    var original: c.sigset_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.sigprocmask(c.SIG.SETMASK, null, &original));
    defer _ = c.sigprocmask(c.SIG.SETMASK, &original, null);

    for ([_]bool{ false, true }) |ttou_blocked| {
        var expected = original;
        posix.sigaddset(&expected, c.SIG.TERM);
        if (ttou_blocked) {
            posix.sigaddset(&expected, c.SIG.TTOU);
        } else {
            posix.sigdelset(&expected, c.SIG.TTOU);
        }
        try std.testing.expectEqual(@as(c_int, 0), c.sigprocmask(c.SIG.SETMASK, &expected, null));

        var terminal = TerminalGuard{ .fd = -1, .original = std.mem.zeroes(c.termios) };
        terminal.restore();

        var actual: c.sigset_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.sigprocmask(c.SIG.SETMASK, null, &actual));
        inline for (.{ c.SIG.INT, c.SIG.TERM, c.SIG.HUP, c.SIG.TTOU, c.SIG.PIPE }) |signal| {
            try std.testing.expectEqual(posix.sigismember(&expected, signal), posix.sigismember(&actual, signal));
        }
    }
}

test "fd range validation rejects descriptors outside fd_set capacity" {
    for ([_]c.fd_t{ c.STDIN_FILENO, c.STDOUT_FILENO, c.STDERR_FILENO }) |fd| {
        try std.testing.expect(tty_proxy_fd_in_range(fd) != 0);
    }
    for ([_]c.fd_t{ -1, 1024, std.math.maxInt(c_int) }) |fd| {
        try std.testing.expectEqual(@as(c_int, 0), tty_proxy_fd_in_range(fd));
    }
}

test "fd sets track validated descriptors" {
    var fds = FdSet.init();
    try std.testing.expect(!fds.isSet(c.STDIN_FILENO));
    fds.set(c.STDIN_FILENO);
    try std.testing.expect(fds.isSet(c.STDIN_FILENO));
    try std.testing.expect(!fds.isSet(c.STDOUT_FILENO));
}

test "buffer stdin headroom threshold" {
    for ([_]usize{ STDIN_READ_HEADROOM - 1, STDIN_READ_HEADROOM, STDIN_READ_HEADROOM + 1 }) |free| {
        var buffer = Buffer{ .end = BUFFER_SIZE - free };
        try std.testing.expectEqual(free >= STDIN_READ_HEADROOM, buffer.canWriteAtLeast(STDIN_READ_HEADROOM));
        try std.testing.expectEqual(BUFFER_SIZE - free, buffer.end);
    }
}

test "buffer compacts a short tail before stdin reads" {
    var buffer = Buffer{ .start = 1024, .end = BUFFER_SIZE - 1 };
    for (&buffer.data, 0..) |*byte, index| byte.* = @intCast(index % 251);
    const original = buffer.data;
    try std.testing.expect(buffer.canWriteAtLeast(STDIN_READ_HEADROOM));
    try std.testing.expectEqual(@as(usize, 0), buffer.start);
    try std.testing.expectEqualStrings(original[1024 .. BUFFER_SIZE - 1], buffer.readSlice());
    try std.testing.expectEqual(@as(usize, 1025), buffer.writeSlice().len);
}

test "buffer waits for enough total headroom before compacting" {
    var buffer = Buffer{ .start = 1, .end = BUFFER_SIZE - (STDIN_READ_HEADROOM - 2) };
    @memset(&buffer.data, 'p');
    try std.testing.expect(!buffer.canWriteAtLeast(STDIN_READ_HEADROOM));
    try std.testing.expectEqual(@as(usize, 1), buffer.start);
    buffer.consume(1);
    try std.testing.expect(buffer.canWriteAtLeast(STDIN_READ_HEADROOM));
    try std.testing.expectEqual(@as(usize, 0), buffer.start);
    try std.testing.expectEqual(STDIN_READ_HEADROOM, buffer.writeSlice().len);
}

fn writeTest(fd: c.fd_t, bytes: []const u8) !usize {
    const rc = c.write(fd, bytes.ptr, bytes.len);
    if (rc < 0) return error.Unexpected;
    return @intCast(rc);
}

fn makePipe() ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.Unexpected;
    return fds;
}

test "stdin reader preserves an available escape sequence near a buffer boundary" {
    const pipe = try makePipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    try std.testing.expectEqual(@as(usize, 3), try writeTest(pipe[1], "\x1b[A"));

    var buffer = Buffer{ .start = STDIN_READ_HEADROOM, .end = BUFFER_SIZE - 1 };
    @memset(&buffer.data, 'p');
    const pending = buffer.end - buffer.start;
    const result = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 3), result.bytes);
    try std.testing.expect(!result.eof);
    try std.testing.expectEqual(@as(usize, 0), buffer.start);
    try std.testing.expectEqual(pending + 3, buffer.readSlice().len);
    try std.testing.expectEqualStrings("\x1b[A", buffer.readSlice()[pending..]);
    for (buffer.readSlice()[0..pending]) |byte| try std.testing.expectEqual(@as(u8, 'p'), byte);
}

test "stdin reader pauses below headroom and resumes after draining" {
    const pipe = try makePipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    try std.testing.expectEqual(@as(usize, 3), try writeTest(pipe[1], "\x1b[A"));

    var buffer = Buffer{ .end = BUFFER_SIZE - (STDIN_READ_HEADROOM - 1) };
    @memset(&buffer.data, 'p');
    const paused = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 0), paused.bytes);
    try std.testing.expect(!paused.eof);
    buffer.consume(1);
    const pending = buffer.end - buffer.start;
    const resumed = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 3), resumed.bytes);
    try std.testing.expectEqualStrings("\x1b[A", buffer.readSlice()[pending..]);
}

test "stdin reader does not wait for Escape continuation" {
    const pipe = try makePipe();
    defer _ = c.close(pipe[0]);
    defer _ = c.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    var buffer = Buffer{};
    try std.testing.expectEqual(@as(usize, 1), try writeTest(pipe[1], "\x1b"));
    const first = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 1), first.bytes);
    try std.testing.expect(!first.eof);
    try std.testing.expectEqualStrings("\x1b", buffer.readSlice());

    try std.testing.expectEqual(@as(usize, 2), try writeTest(pipe[1], "[A"));
    const rest = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 2), rest.bytes);
    try std.testing.expectEqualStrings("\x1b[A", buffer.readSlice());
}

test "stdin reader retains bytes read before EOF" {
    const pipe = try makePipe();
    defer _ = c.close(pipe[0]);
    var writer_open = true;
    defer {
        if (writer_open) _ = c.close(pipe[1]);
    }
    try setNonBlocking(pipe[0]);
    try std.testing.expectEqual(@as(usize, 3), try writeTest(pipe[1], "\x1b[A"));
    _ = c.close(pipe[1]);
    writer_open = false;

    var buffer = Buffer{};
    const result = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 3), result.bytes);
    try std.testing.expect(result.eof);
    try std.testing.expectEqualStrings("\x1b[A", buffer.readSlice());
}

test "stdio flags guard restores shared descriptors and existing nonblocking flags" {
    for ([_]bool{ false, true }) |initially_nonblocking| {
        const pipe = try makePipe();
        defer _ = c.close(pipe[0]);
        defer _ = c.close(pipe[1]);
        const alias1 = c.dup(pipe[0]);
        defer _ = c.close(alias1);
        const alias2 = c.dup(pipe[0]);
        defer _ = c.close(alias2);

        if (initially_nonblocking) try setNonBlocking(pipe[0]);
        const original = try getFdFlags(pipe[0]);
        const guard = try StdioFlagsGuard.capture(.{ pipe[0], alias1, alias2 });
        {
            defer guard.restore();
            try guard.enableNonBlocking();
            for (guard.fds) |fd| {
                try std.testing.expect((try getFdFlags(fd)).NONBLOCK);
            }
        }
        for (guard.fds) |fd| {
            try std.testing.expectEqual(original, try getFdFlags(fd));
        }
    }
}

test "stdio flags guard restores independent descriptors" {
    const pipe1 = try makePipe();
    defer _ = c.close(pipe1[0]);
    defer _ = c.close(pipe1[1]);
    const pipe2 = try makePipe();
    defer _ = c.close(pipe2[0]);
    defer _ = c.close(pipe2[1]);
    try setNonBlocking(pipe2[0]);

    const guard = try StdioFlagsGuard.capture(.{ pipe1[0], pipe1[1], pipe2[0] });
    {
        defer guard.restore();
        try guard.enableNonBlocking();
        for (guard.fds) |fd| {
            try std.testing.expect((try getFdFlags(fd)).NONBLOCK);
        }
    }
    for (guard.fds, guard.original) |fd, original| {
        try std.testing.expectEqual(original, try getFdFlags(fd));
    }
}

test {
    _ = @import("config.zig");
    _ = @import("startup.zig");
}

test "EOF without a status defaults to zero" {
    var session = DirectSession{};
    try session.receive("");
    try std.testing.expectEqual(@as(u8, 0), session.exitStatus());
}

test "accept every single-byte status" {
    for (0..256) |status| {
        var session = DirectSession{};
        const bytes = [_]u8{@intCast(status)};
        try session.receive(&bytes);
        try session.receive("");
        try std.testing.expectEqual(@as(u8, @intCast(status)), session.exitStatus());
    }
}

test "reject extra status bytes across arbitrary read boundaries" {
    const bytes = [_]u8{ 0, 255 };
    for (0..3) |split| {
        var session = DirectSession{};
        if (split == 2) {
            try std.testing.expectError(error.TooManyExitStatusBytes, session.receive(&bytes));
        } else {
            try session.receive(bytes[0..split]);
            try std.testing.expectError(error.TooManyExitStatusBytes, session.receive(bytes[split..]));
        }
    }
}

test "operation mode parser accepts R C E D" {
    const testing = std.testing;

    try testing.expectEqual(OperationMode.raw, try parseMode('R'));
    try testing.expectEqual(OperationMode.canonical, try parseMode('C'));
    try testing.expectEqual(OperationMode.err, try parseMode('E'));
    try testing.expectEqual(OperationMode.direct, try parseMode('D'));
    try testing.expectError(error.InvalidMode, parseMode(' '));
    try testing.expectError(error.InvalidMode, parseMode('x'));
}
