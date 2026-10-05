const std = @import("std");
const posix = std.posix;
const net = std.net;

const config = @import("config.zig");
const StartupEncoder = @import("startup.zig").StartupEncoder;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/select.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

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
// The proxy sends no payload. Its write-side EOF requests session cancellation.
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

    fn canWrite(self: *Buffer) bool {
        return self.canWriteAtLeast(1);
    }

    fn canWriteAtLeast(self: *Buffer, minimum: usize) bool {
        self.ensureWriteSpace(minimum);
        return self.data.len - self.end >= minimum;
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
};

const StdinReadResult = struct {
    bytes: usize = 0,
    eof: bool = false,
};

// Batch available terminal input before the next socket write. A short tty read
// need not drain all available bytes; retrying can reduce proxy-induced gaps
// between fragments of an already available key sequence.
fn readTerminalInput(fd: posix.fd_t, buffer: *Buffer) !StdinReadResult {
    var result = StdinReadResult{};

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
        } else switch (posix.errno(rc)) {
            .INTR, .AGAIN => break,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    return result;
}

// Snapshot every descriptor before changing any flags: standard descriptors
// may share an open-file description, so changing one can change the others.
const StdioFlagsGuard = struct {
    fds: [3]posix.fd_t,
    original: [3]c_int,

    fn capture(fds: [3]posix.fd_t) !StdioFlagsGuard {
        var guard = StdioFlagsGuard{ .fds = fds, .original = undefined };
        for (fds, 0..) |fd, i| {
            guard.original[i] = try getFdFlags(fd);
        }
        return guard;
    }

    fn enableNonBlocking(self: *const StdioFlagsGuard) !void {
        for (self.fds, self.original) |fd, flags| {
            try setFdFlags(fd, flags | c.O_NONBLOCK);
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
    fd: posix.fd_t,
    original: c.termios,

    fn capture(fd: posix.fd_t) !TerminalGuard {
        var current: c.struct_termios = undefined;

        while (true) {
            const rc = c.tcgetattr(fd, &current);
            switch (posix.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        return .{ .fd = fd, .original = current };
    }

    fn enableRaw(self: *const TerminalGuard) !void {
        var current = self.original;

        c.cfmakeraw(&current);

        while (true) {
            const rc = c.tcsetattr(self.fd, c.TCSANOW, &current);
            switch (posix.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    fn restore(self: *TerminalGuard) void {
        while (true) {
            const rc = c.tcsetattr(self.fd, c.TCSANOW, &self.original);
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => return,
            }
        }
    }
};

pub fn main() void {
    // Non-signal runtime failures are reported as a generic exit status 1.
    const outcome = run() catch {
        std.process.exit(1);
    };

    switch (outcome) {
        .connection_closed => {},
        .error_mode_complete => std.process.exit(1),
        .signaled => |signal| std.process.exit(@intCast(128 + signal)),
        .completed => |status| std.process.exit(status),
    }
}

// Buffered terminal -> peer bytes.
var to_lisp = Buffer{};

// Buffered peer -> terminal bytes.
var to_term = Buffer{};

// Runtime contract: tty-proxy is expected to be launched by a user
// from a shell in a terminal, with normal shell terminal settings.
//
// Unusual terminal configurations (e.g. noncanonical polling with
// VMIN=0) are out of scope. A zero-byte tty read is treated as EOF.
//
// Owns startup, the readiness loop, and shutdown/drain behavior.
fn run() !RunOutcome {
    // Leave default signal actions active during potentially blocking startup.
    // No shared fd flags or terminal settings have been changed yet.
    if (!posix.isatty(posix.STDIN_FILENO)) {
        return error.StdinIsNotATerminal;
    }

    const allocator = std.heap.c_allocator;

    const socket_path = try config.resolveSocket(
        allocator,
        std.mem.sliceTo(std.os.argv[0], 0),
    );

    var lisp_stream = try net.connectUnixSocket(socket_path);
    defer lisp_stream.close();

    // From here on, termination must run cleanup. Keep signals blocked except
    // during pselect() to avoid a race between checking the flag and sleeping.
    const wait_signal_mask = try blockTerminationSignals();
    installSignalHandlers();

    const stdio_flags = try StdioFlagsGuard.capture(.{
        posix.STDIN_FILENO,
        posix.STDOUT_FILENO,
        posix.STDERR_FILENO,
    });
    var stdio_changed = false;
    defer if (stdio_changed) stdio_flags.restore();

    var terminal = try TerminalGuard.capture(posix.STDIN_FILENO);
    var restore_terminal = false;
    defer if (restore_terminal) terminal.restore();

    // D leaves stdio flags alone. Pumped modes enable nonblocking I/O
    // after selection, with cleanup armed before changing any descriptor.
    try setNonBlocking(lisp_stream.handle);

    // stdin EOF: stop reading terminal input
    var term_open = true;

    // peer EOF: stop reading peer input, but keep draining buffered output
    var peer_open = true;

    // Capture terminal metadata now, then encode incrementally in the loop.
    var startup = try StartupEncoder.init(posix.STDIN_FILENO);
    var startup_complete = false;

    var mode: OperationMode = .none;
    var direct = DirectSession{};
    var direct_timer: ?std.time.Timer = null;
    var shutdown_deadline: ?u64 = null;

    while (true) {
        if (mode == .direct) {
            const cancellations = termination_count.load(.monotonic);
            if (cancellations > 0) {
                const now = direct_timer.?.read();
                if (shutdown_deadline == null) {
                    // EOF requests detachment of this session, not termination
                    // of the long-lived peer. Stop even an early D's startup.
                    try shutdownWrite(lisp_stream.handle);
                    to_lisp.consume(to_lisp.readSlice().len);
                    shutdown_deadline = now + 2 * std.time.ns_per_s;
                }
                if (cancellations > 1 or now >= shutdown_deadline.?) {
                    return .{ .signaled = last_termination_signal.load(.monotonic) };
                }
            }
        } else if (terminationSignal()) {
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

        const output_fd: posix.fd_t = if (mode == .err)
            posix.STDERR_FILENO
        else
            posix.STDOUT_FILENO;

        var read_fds = c.fd_set{};
        var write_fds = c.fd_set{};
        var except_fds = c.fd_set{};

        if (peer_open) {
            // Interactive input starts only after startup has fully drained
            // and the peer has selected C or R mode.
            if (startup_complete and mode.canReadStdin() and term_open and
                to_lisp.canWriteAtLeast(STDIN_READ_HEADROOM))
            {
                c.FD_SET(posix.STDIN_FILENO, &read_fds);
                c.FD_SET(posix.STDIN_FILENO, &except_fds);
            }

            // D uses the free to_term storage as a control-read scratch buffer;
            // other modes queue the bytes for stdout/stderr.
            if (to_term.canWrite()) {
                c.FD_SET(lisp_stream.handle, &read_fds);
                c.FD_SET(lisp_stream.handle, &except_fds);
            }

            // After the peer selects E mode, do not send any more buffered bytes back.
            if (mode.canWritePeer() and shutdown_deadline == null and to_lisp.canRead()) {
                c.FD_SET(lisp_stream.handle, &write_fds);
                c.FD_SET(lisp_stream.handle, &except_fds);
            }
        }

        if (to_term.canRead()) {
            c.FD_SET(output_fd, &write_fds);
            c.FD_SET(output_fd, &except_fds);
        }

        // Build readiness each iteration from current buffers/state, then wait
        // until one side can make progress.
        var timeout: c.timespec = undefined;
        const timeout_ptr: ?*const c.timespec = if (shutdown_deadline) |deadline| blk: {
            const remaining = deadline -| direct_timer.?.read();
            timeout = .{
                .tv_sec = @intCast(remaining / std.time.ns_per_s),
                .tv_nsec = @intCast(remaining % std.time.ns_per_s),
            };
            break :blk &timeout;
        } else null;

        const select_result = c.pselect(
            lisp_stream.handle + 1,
            &read_fds,
            &write_fds,
            &except_fds,
            timeout_ptr,
            &wait_signal_mask,
        );

        if (select_result < 0) {
            switch (posix.errno(select_result)) {
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        // Recompute readiness from the fd_sets returned by pselect().
        const term_in_ready = c.FD_ISSET(posix.STDIN_FILENO, &read_fds) != 0 or
            c.FD_ISSET(posix.STDIN_FILENO, &except_fds) != 0;
        const lisp_in_ready = (c.FD_ISSET(lisp_stream.handle, &read_fds) != 0 or
            c.FD_ISSET(lisp_stream.handle, &except_fds) != 0);
        const lisp_out_ready = (c.FD_ISSET(lisp_stream.handle, &write_fds) != 0);
        const term_out_ready = c.FD_ISSET(output_fd, &write_fds) != 0;

        var stdin_bytes_read: usize = 0;

        if (term_in_ready) {
            const result = try readTerminalInput(posix.STDIN_FILENO, &to_lisp);
            stdin_bytes_read = result.bytes;
            if (result.eof) term_open = false;
        }

        if (lisp_in_ready) {
            // The first byte received from the peer is the mode selector. Any
            // remaining bytes are terminal payload or D's optional status.
            var lisp_slice = to_term.writeSlice();
            const read_rc = c.read(
                lisp_stream.handle,
                lisp_slice.ptr,
                lisp_slice.len,
            );
            if (read_rc == 0) {
                if (mode == .direct) {
                    return if (terminationSignal())
                        .{ .signaled = terminate_signal.load(.monotonic) }
                    else
                        .{ .completed = direct.exitStatus() };
                }
                peer_open = false;
            } else if (read_rc > 0) {
                var count: usize = @intCast(read_rc);

                if (mode == .none) {
                    // The first byte is control data, not payload.
                    mode = try parseOperationModeByte(lisp_slice[0]);
                    if (mode == .raw or mode == .direct) restore_terminal = true;
                    if (mode == .raw) try terminal.enableRaw();
                    if (mode == .direct) {
                        direct_timer = try std.time.Timer.start();
                    } else {
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
            } else switch (posix.errno(read_rc)) {
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
            const write_rc = c.write(lisp_stream.handle, chunk.ptr, chunk.len);
            if (write_rc < 0) switch (posix.errno(write_rc)) {
                .INTR, .AGAIN => {},
                else => |err| return posix.unexpectedErrno(err),
            } else if (write_rc > 0) {
                const written: usize = @intCast(write_rc);
                to_lisp.consume(written);
            }
        }

        if ((startup_complete and !term_open and !to_lisp.canRead()) or mode == .err) {
            _ = c.shutdown(lisp_stream.handle, c.SHUT_WR);
        }

        if (term_out_ready) {
            // Drain buffered peer output to the selected terminal stream.
            const chunk = to_term.readSlice();
            const write_rc = c.write(output_fd, chunk.ptr, chunk.len);
            if (write_rc < 0) switch (posix.errno(write_rc)) {
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

// Translates the peer's single-byte mode protocol into an enum used by the
// rest of the runtime.
fn parseOperationModeByte(ch: u8) !OperationMode {
    return switch (ch) {
        'R' => .raw,
        'C' => .canonical,
        'E' => .err,
        'D' => .direct,
        else => return error.InvalidMode,
    };
}

// All I/O is driven from pselect(), so every participating fd is switched to
// non-blocking mode.
fn setNonBlocking(fd: posix.fd_t) !void {
    try setFdFlags(fd, (try getFdFlags(fd)) | c.O_NONBLOCK);
}

fn shutdownWrite(fd: posix.fd_t) !void {
    while (true) {
        const rc = c.shutdown(fd, c.SHUT_WR);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn getFdFlags(fd: posix.fd_t) !c_int {
    while (true) {
        const rc = c.fcntl(fd, c.F_GETFL);
        if (rc >= 0) return rc;
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setFdFlags(fd: posix.fd_t, flags: c_int) !void {
    while (true) {
        const rc = c.fcntl(fd, c.F_SETFL, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

// Block the signals checked by the event loop, and return a mask that
// temporarily unblocks them during pselect().
fn blockTerminationSignals() !c.sigset_t {
    var termination_set: c.sigset_t = undefined;
    if (c.sigemptyset(&termination_set) < 0) {
        return posix.unexpectedErrno(posix.errno(-1));
    }
    inline for (.{ posix.SIG.INT, posix.SIG.TERM, posix.SIG.HUP }) |signal| {
        if (c.sigaddset(&termination_set, @as(c_int, signal)) < 0) {
            return posix.unexpectedErrno(posix.errno(-1));
        }
    }

    if (c.sigprocmask(c.SIG_BLOCK, &termination_set, null) < 0) {
        return posix.unexpectedErrno(posix.errno(-1));
    }

    var wait_mask: c.sigset_t = undefined;
    if (c.sigprocmask(c.SIG_SETMASK, null, &wait_mask) < 0) {
        return posix.unexpectedErrno(posix.errno(-1));
    }

    inline for (.{ posix.SIG.INT, posix.SIG.TERM, posix.SIG.HUP }) |signal| {
        if (c.sigdelset(&wait_mask, @as(c_int, signal)) < 0) {
            return posix.unexpectedErrno(posix.errno(-1));
        }
    }

    return wait_mask;
}

// Handlers record cancellation only; half-close and cleanup run in the loop.
fn installSignalHandlers() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
    posix.sigaction(posix.SIG.HUP, &action, null);

    // Let write() report EPIPE instead of terminating the process, so the
    // normal error path can run and restore terminal settings.
    const ignore_pipe = posix.Sigaction{
        .handler = .{ .handler = @ptrFromInt(1) },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.PIPE, &ignore_pipe, null);
}

fn signalHandler(signal: i32) callconv(.c) void {
    last_termination_signal.store(signal, .monotonic);
    _ = termination_count.fetchAdd(1, .monotonic);
    _ = terminate_signal.cmpxchgStrong(0, signal, .monotonic, .monotonic);
}

fn terminationSignal() bool {
    return terminate_signal.load(.monotonic) != 0;
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

test "stdin reader preserves an available escape sequence near a buffer boundary" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    try std.testing.expectEqual(@as(usize, 3), try posix.write(pipe[1], "\x1b[A"));

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
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    try std.testing.expectEqual(@as(usize, 3), try posix.write(pipe[1], "\x1b[A"));

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
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    var buffer = Buffer{};
    try std.testing.expectEqual(@as(usize, 1), try posix.write(pipe[1], "\x1b"));
    const first = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 1), first.bytes);
    try std.testing.expect(!first.eof);
    try std.testing.expectEqualStrings("\x1b", buffer.readSlice());

    try std.testing.expectEqual(@as(usize, 2), try posix.write(pipe[1], "[A"));
    const rest = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 2), rest.bytes);
    try std.testing.expectEqualStrings("\x1b[A", buffer.readSlice());
}

test "stdin reader retains bytes read before EOF" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    var writer_open = true;
    defer if (writer_open) posix.close(pipe[1]);
    try setNonBlocking(pipe[0]);
    try std.testing.expectEqual(@as(usize, 3), try posix.write(pipe[1], "\x1b[A"));
    posix.close(pipe[1]);
    writer_open = false;

    var buffer = Buffer{};
    const result = try readTerminalInput(pipe[0], &buffer);
    try std.testing.expectEqual(@as(usize, 3), result.bytes);
    try std.testing.expect(result.eof);
    try std.testing.expectEqualStrings("\x1b[A", buffer.readSlice());
}

test "stdio flags guard restores shared descriptors and existing nonblocking flags" {
    for ([_]bool{ false, true }) |initially_nonblocking| {
        const pipe = try posix.pipe();
        defer posix.close(pipe[0]);
        defer posix.close(pipe[1]);
        const alias1 = try posix.dup(pipe[0]);
        defer posix.close(alias1);
        const alias2 = try posix.dup(pipe[0]);
        defer posix.close(alias2);

        if (initially_nonblocking) try setNonBlocking(pipe[0]);
        const original = try getFdFlags(pipe[0]);
        const guard = try StdioFlagsGuard.capture(.{ pipe[0], alias1, alias2 });
        {
            defer guard.restore();
            try guard.enableNonBlocking();
            for (guard.fds) |fd| {
                try std.testing.expect((try getFdFlags(fd)) & c.O_NONBLOCK != 0);
            }
        }
        for (guard.fds) |fd| {
            try std.testing.expectEqual(original, try getFdFlags(fd));
        }
    }
}

test "stdio flags guard restores independent descriptors" {
    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);
    defer posix.close(pipe1[1]);
    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);
    defer posix.close(pipe2[1]);
    try setNonBlocking(pipe2[0]);

    const guard = try StdioFlagsGuard.capture(.{ pipe1[0], pipe1[1], pipe2[0] });
    {
        defer guard.restore();
        try guard.enableNonBlocking();
        for (guard.fds) |fd| {
            try std.testing.expect((try getFdFlags(fd)) & c.O_NONBLOCK != 0);
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

    try testing.expectEqual(OperationMode.raw, try parseOperationModeByte('R'));
    try testing.expectEqual(OperationMode.canonical, try parseOperationModeByte('C'));
    try testing.expectEqual(OperationMode.err, try parseOperationModeByte('E'));
    try testing.expectEqual(OperationMode.direct, try parseOperationModeByte('D'));
    try testing.expectError(error.InvalidMode, parseOperationModeByte(' '));
    try testing.expectError(error.InvalidMode, parseOperationModeByte('x'));
}
