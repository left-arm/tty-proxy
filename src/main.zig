const std = @import("std");
const posix = std.posix;
const net = std.net;

const config = @import("config.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/select.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

// Shared fixed-size buffer capacity used for both directions of the proxy and
// for the encoded startup plist.
const BUFFER_SIZE: usize = 16 * 1024;

// Set asynchronously by SIGINT/SIGTERM handlers and polled from the main loop.
var terminate_signal = std.atomic.Value(i32).init(0);

// High-level process exit reasons used by main() to select the final exit code.
const RunOutcome = enum {
    connection_closed,
    error_mode_complete,
    signaled,
};

// The peer chooses the terminal behavior by sending one leading mode byte. R
// asks tty-proxy to enable raw mode and restore the previous settings on exit;
// C and E leave the existing terminal mode unchanged.
const OperationMode = enum {
    none,
    raw,
    canonical,
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

// A compact single-producer/single-consumer byte buffer used for both directions
// of the proxy. It compacts in-place when the write side reaches the end.
const Buffer = struct {
    data: [BUFFER_SIZE]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn canRead(self: *const Buffer) bool {
        return self.start < self.end;
    }

    fn canWrite(self: *Buffer) bool {
        self.ensureWriteSpace();
        return self.end < self.data.len;
    }

    fn writeSlice(self: *Buffer) []u8 {
        self.ensureWriteSpace();
        return self.data[self.end..];
    }

    fn readSlice(self: *const Buffer) []const u8 {
        return self.data[self.start..self.end];
    }

    fn append(self: *Buffer, input: []const u8) usize {
        self.ensureWriteSpace();
        const capacity = self.data.len - self.end;
        const count = @min(capacity, input.len);
        std.mem.copyForwards(
            u8,
            self.data[self.end .. self.end + count],
            input[0..count],
        );
        self.end += count;
        return count;
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

    fn ensureWriteSpace(self: *Buffer) void {
        if (self.end == self.data.len and self.start > 0) {
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

// Enables raw mode and restores the original termios state on scope exit.
const RawModeGuard = struct {
    fd: posix.fd_t,
    original: c.termios,

    fn enable(fd: posix.fd_t) !RawModeGuard {
        // Capture the current terminal settings, derive a raw variant from them,
        // then install that raw variant.
        var current: c.struct_termios = undefined;
        while (true) {
            const rc = c.tcgetattr(fd, &current);
            switch (posix.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        const original = current;
        c.cfmakeraw(&current);

        while (true) {
            const rc = c.tcsetattr(fd, c.TCSANOW, &current);
            switch (posix.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        return .{ .fd = fd, .original = original };
    }

    fn restore(self: *RawModeGuard) void {
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
        .signaled => {
            const signal = terminate_signal.load(.monotonic);
            const code: u8 = @intCast(128 + signal);
            std.process.exit(code);
        },
    }
}

// Buffered terminal -> peer bytes.
var to_lisp = Buffer{};

// Buffered peer -> terminal bytes.
var to_term = Buffer{};

// Owns startup, the readiness loop, and shutdown/drain behavior.
fn run() !RunOutcome {
    installSignalHandlers();

    if (!posix.isatty(posix.STDIN_FILENO)) {
        return error.StdinIsNotATerminal;
    }

    if (terminationSignal()) {
        return .signaled;
    }

    const allocator = std.heap.c_allocator;

    const socket_path = try config.resolveSocket(
        allocator,
        std.mem.sliceTo(std.os.argv[0], 0),
    );

    var lisp_stream = try net.connectUnixSocket(socket_path);
    defer lisp_stream.close();

    try setNonBlocking(posix.STDIN_FILENO);
    try setNonBlocking(posix.STDOUT_FILENO);
    try setNonBlocking(posix.STDERR_FILENO);
    try setNonBlocking(lisp_stream.handle);

    // stdin EOF: stop reading terminal input
    var term_open = true;

    // peer EOF: stop reading peer input, but keep draining buffered output
    var peer_open = true;

    // Queue startup metadata before entering the select loop so the peer sees
    // it before choosing the terminal mode.
    try encodeStartupInfo(&to_lisp);

    var raw_mode: ?RawModeGuard = null;
    defer if (raw_mode) |*guard| guard.restore();

    var mode: OperationMode = .none;

    while (true) {
        if (terminationSignal()) {
            return .signaled;
        }

        // In error mode, peer payload is treated as an error message and routed
        // to stderr instead of stdout.
        const error_mode = mode == .err;

        const output_fd: posix.fd_t = if (error_mode)
            posix.STDERR_FILENO
        else
            posix.STDOUT_FILENO;

        var read_fds = c.fd_set{};
        var write_fds = c.fd_set{};
        var except_fds = c.fd_set{};

        if (peer_open) {
            // Read terminal input only after the peer has selected C or R mode.
            if (mode.canReadStdin() and term_open and to_lisp.canWrite()) {
                c.FD_SET(posix.STDIN_FILENO, &read_fds);
                c.FD_SET(posix.STDIN_FILENO, &except_fds);
            }

            // Peer output always goes through to_term, then to stdout or stderr.
            if (to_term.canWrite()) {
                c.FD_SET(lisp_stream.handle, &read_fds);
                c.FD_SET(lisp_stream.handle, &except_fds);
            }

            // After the peer selects E mode, do not send any more buffered bytes back.
            if (mode.canWritePeer() and to_lisp.canRead()) {
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
        const select_result = c.pselect(
            lisp_stream.handle + 1,
            &read_fds,
            &write_fds,
            &except_fds,
            null,
            null,
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

        if (term_in_ready) {
            // Buffer stdin bytes first; actual peer writes are handled below so
            // both directions follow the same drain logic.
            const chunk = to_lisp.writeSlice();
            const read_rc = c.read(posix.STDIN_FILENO, chunk.ptr, chunk.len);
            if (read_rc == 0) {
                term_open = false;
            } else if (read_rc > 0) {
                const count: usize = @intCast(read_rc);
                to_lisp.produce(count);
            } else switch (posix.errno(read_rc)) {
                .INTR, .AGAIN => {},
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        if (lisp_in_ready) {
            // The first byte received from the peer is the mode selector. Any
            // remaining bytes from that same read are normal payload.
            var lisp_slice = to_term.writeSlice();
            const read_rc = c.read(
                lisp_stream.handle,
                lisp_slice.ptr,
                lisp_slice.len,
            );
            if (read_rc == 0) {
                peer_open = false;
            } else if (read_rc > 0) {
                var count: usize = @intCast(read_rc);

                if (mode == .none) {
                    // The first byte is control data, not payload.
                    try consumeOperationMode(
                        lisp_slice[0],
                        &mode,
                        &raw_mode,
                    );

                    count -= 1;
                    if (count > 0) {
                        std.mem.copyForwards(
                            u8,
                            lisp_slice[0..count],
                            lisp_slice[1 .. count + 1],
                        );
                    }
                }

                to_term.produce(count);
            } else switch (posix.errno(read_rc)) {
                .INTR, .AGAIN => {},
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        if (peer_open and mode.canWritePeer() and lisp_out_ready) {
            // Re-check current state here because peer EOF or E mode may have
            // been observed earlier in the same loop iteration.
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
            return if (error_mode) .error_mode_complete else .connection_closed;
        }
    }
}

// Appends exactly input.len bytes or fails if the startup plist would exceed
// BUFFER_SIZE.
inline fn appendSlice(buffer: *Buffer, input: []const u8) !void {
    const appended = buffer.append(input);
    if (appended != input.len) return error.StartupInfoTooLarge;
}

inline fn appendChar(buffer: *Buffer, ch: u8) !void {
    try appendSlice(buffer, &.{ch});
}

// Emits a minimally escaped double-quoted Lisp string.
fn appendLispString(buffer: *Buffer, input: []const u8) !void {
    try appendChar(buffer, '"');
    for (input) |ch| {
        switch (ch) {
            '\\' => try appendSlice(buffer, "\\\\"),
            '"' => try appendSlice(buffer, "\\\""),
            else => try appendChar(buffer, ch),
        }
    }
    try appendChar(buffer, '"');
}

inline fn appendUnsigned(buffer: *Buffer, value: anytype) !void {
    // Window-size fields are serialized as decimal integers in the plist.
    var number_buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&number_buf, "{}", .{value});
    try appendSlice(buffer, text);
}

// Appends the controlling tty path for stdin, quoted as a Lisp string.
fn appendTtyName(buffer: *Buffer) !void {
    var tty_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (true) {
        const rc = c.ttyname_r(posix.STDIN_FILENO, tty_buf[0..].ptr, tty_buf.len);
        if (rc == 0) break;
        if (rc == @intFromEnum(posix.E.INTR)) continue;
        return posix.unexpectedErrno(@enumFromInt(rc));
    }

    try appendLispString(buffer, std.mem.sliceTo(tty_buf[0..], 0));
}

// Encodes the initial plist sent to the peer before normal byte forwarding
// begins.
fn encodeStartupInfo(buffer: *Buffer) !void {
    var winsize = c.struct_winsize{};

    const ioctl_rc = c.ioctl(posix.STDIN_FILENO, c.TIOCGWINSZ, &winsize);
    if (ioctl_rc < 0) {
        return posix.unexpectedErrno(posix.errno(ioctl_rc));
    }

    try appendSlice(buffer, "(:args (");
    for (std.os.argv, 0..) |arg, i| {
        if (i > 0) try appendChar(buffer, ' ');
        try appendLispString(buffer, std.mem.sliceTo(arg, 0));
    }

    try appendSlice(buffer, ") :tty ");
    try appendTtyName(buffer);

    try appendSlice(buffer, " :env (");
    var first_env = true;
    for (std.os.environ) |line| {
        const line_slice = std.mem.sliceTo(line, 0);

        const name_end = std.mem.indexOfScalar(u8, line_slice, '=') orelse
            continue;

        const name = line_slice[0..name_end];
        const value = line_slice[name_end + 1 ..];

        if (!first_env) try appendChar(buffer, ' ');
        first_env = false;

        try appendChar(buffer, '(');
        try appendLispString(buffer, name);
        try appendChar(buffer, ' ');
        try appendLispString(buffer, value);
        try appendChar(buffer, ')');
    }

    try appendSlice(buffer, ") :size (:rows ");
    try appendUnsigned(buffer, winsize.ws_row);
    try appendSlice(buffer, " :cols ");
    try appendUnsigned(buffer, winsize.ws_col);
    try appendSlice(buffer, " :xpixels ");
    try appendUnsigned(buffer, winsize.ws_xpixel);
    try appendSlice(buffer, " :ypixels ");
    try appendUnsigned(buffer, winsize.ws_ypixel);

    try appendSlice(buffer, "))");
}

// Consumes the peer's one-byte mode selection and enables raw mode eagerly
// when requested.
fn consumeOperationMode(
    ch: u8,
    mode: *OperationMode,
    raw_mode: *?RawModeGuard,
) !void {
    mode.* = try parseOperationModeByte(ch);
    if (mode.* == .raw) {
        raw_mode.* = try RawModeGuard.enable(posix.STDIN_FILENO);
    }
}

// Translates the peer's single-byte mode protocol into an enum used by the
// rest of the runtime.
fn parseOperationModeByte(ch: u8) !OperationMode {
    return switch (ch) {
        'R' => .raw,
        'C' => .canonical,
        'E' => .err,
        else => return error.InvalidMode,
    };
}

// All I/O is driven from pselect(), so every participating fd is switched to
// non-blocking mode.
fn setNonBlocking(fd: posix.fd_t) !void {
    var flags: c_int = 0;

    flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0) {
        return posix.unexpectedErrno(posix.errno(flags));
    }

    flags = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
    if (flags < 0) {
        return posix.unexpectedErrno(posix.errno(flags));
    }
}

// Signals are reduced to an atomic flag so the main loop can exit from a safe
// point without doing real work in the handler.
fn installSignalHandlers() void {
    const action = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
}

fn signalHandler(signal: i32) callconv(.c) void {
    if (signal == posix.SIG.INT or signal == posix.SIG.TERM) {
        if (terminate_signal.load(.monotonic) == 0) {
            terminate_signal.store(signal, .monotonic);
        }
    }
}

fn terminationSignal() bool {
    return terminate_signal.load(.monotonic) != 0;
}

test {
    _ = @import("config.zig");
}

test "operation mode parser accepts R C E" {
    const testing = std.testing;

    try testing.expectEqual(OperationMode.raw, try parseOperationModeByte('R'));
    try testing.expectEqual(OperationMode.canonical, try parseOperationModeByte('C'));
    try testing.expectEqual(OperationMode.err, try parseOperationModeByte('E'));
    try testing.expectError(error.InvalidMode, parseOperationModeByte(' '));
    try testing.expectError(error.InvalidMode, parseOperationModeByte('x'));
}
