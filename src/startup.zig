const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

// Resumable startup-plist encoder. No socket I/O or metadata-sized allocation
// is performed here; encode() fills whatever space the readiness loop provides.
// Once encoding starts, keep the encoder in place: tokens can reference its
// owned tty and size buffers. Argument/environment storage must remain valid.
pub const StartupEncoder = struct {
    const Phase = enum {
        prefix,
        arg,
        arg_separator,
        tty,
        env_open,
        env_next,
        env_name,
        env_space,
        env_value,
        env_close,
        finished,
    };
    const Token = union(enum) {
        none,
        literal: struct { bytes: []const u8, offset: usize = 0 },
        quoted: struct {
            bytes: []const u8,
            offset: usize = 0,
            phase: enum { opening, body, escaped } = .opening,
        },
    };

    args: []const [*:0]const u8,
    env: []const [*:0]const u8,
    tty_buffer: [std.fs.max_path_bytes]u8 = undefined,
    tty_len: usize,
    size_buffer: [160]u8 = undefined,
    size_len: usize,
    phase: Phase = .prefix,
    token: Token = .none,
    arg_index: usize = 0,
    env_index: usize = 0,
    first_env: bool = true,
    env_name: []const u8 = "",
    env_value: []const u8 = "",

    // Capture fallible terminal metadata before any startup bytes are sent.
    pub fn init(fd: posix.fd_t) !StartupEncoder {
        var tty_buffer: [std.fs.max_path_bytes]u8 = undefined;
        while (true) {
            const rc = c.ttyname_r(fd, &tty_buffer, tty_buffer.len);
            if (rc == 0) break;
            if (rc == @intFromEnum(posix.E.INTR)) continue;
            return posix.unexpectedErrno(@enumFromInt(rc));
        }

        var size = c.struct_winsize{};
        while (true) {
            const rc = c.ioctl(fd, c.TIOCGWINSZ, &size);
            switch (posix.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
        return initWithInfo(std.os.argv, std.os.environ, std.mem.sliceTo(&tty_buffer, 0), size);
    }

    fn initWithInfo(
        args: []const [*:0]const u8,
        env: []const [*:0]const u8,
        tty: []const u8,
        size: c.struct_winsize,
    ) !StartupEncoder {
        var encoder = StartupEncoder{
            .args = args,
            .env = env,
            .tty_len = tty.len,
            .size_len = 0,
        };
        if (tty.len > encoder.tty_buffer.len) return error.NameTooLong;
        @memcpy(encoder.tty_buffer[0..tty.len], tty);
        const suffix = try std.fmt.bufPrint(
            &encoder.size_buffer,
            ") :size (:rows {} :cols {} :xpixels {} :ypixels {}))",
            .{ size.ws_row, size.ws_col, size.ws_xpixel, size.ws_ypixel },
        );
        encoder.size_len = suffix.len;
        return encoder;
    }

    pub fn done(self: *const StartupEncoder) bool {
        if (self.phase != .finished) return false;
        return switch (self.token) {
            .none => true,
            .literal => |segment| segment.offset == segment.bytes.len,
            .quoted => false,
        };
    }

    pub fn encode(self: *StartupEncoder, output: []u8) usize {
        var count: usize = 0;
        while (count < output.len) {
            output[count] = self.nextByte() orelse break;
            count += 1;
        }
        return count;
    }

    fn nextByte(self: *StartupEncoder) ?u8 {
        while (true) {
            switch (self.token) {
                .none => if (!self.nextToken()) return null,
                .literal => |*segment| {
                    if (segment.offset < segment.bytes.len) {
                        const byte = segment.bytes[segment.offset];
                        segment.offset += 1;
                        return byte;
                    }
                    self.token = .none;
                },
                .quoted => |*string| switch (string.phase) {
                    .opening => {
                        string.phase = .body;
                        return '"';
                    },
                    .body => {
                        if (string.offset == string.bytes.len) {
                            self.token = .none;
                            return '"';
                        }
                        const byte = string.bytes[string.offset];
                        if (byte == '\\' or byte == '"') {
                            // Keep the input cursor on this byte until the
                            // escaped byte is emitted, even across fills.
                            string.phase = .escaped;
                            return '\\';
                        }
                        string.offset += 1;
                        return byte;
                    },
                    .escaped => {
                        const byte = string.bytes[string.offset];
                        string.offset += 1;
                        string.phase = .body;
                        return byte;
                    },
                },
            }
        }
    }

    fn literal(self: *StartupEncoder, bytes: []const u8) void {
        self.token = .{ .literal = .{ .bytes = bytes } };
    }

    fn quoted(self: *StartupEncoder, bytes: []const u8) void {
        self.token = .{ .quoted = .{ .bytes = bytes } };
    }

    fn nextToken(self: *StartupEncoder) bool {
        while (true) {
            switch (self.phase) {
                .prefix => {
                    self.literal("(:args (");
                    self.phase = .arg;
                },
                .arg => {
                    if (self.arg_index < self.args.len) {
                        self.quoted(std.mem.sliceTo(self.args[self.arg_index], 0));
                        self.arg_index += 1;
                        self.phase = .arg_separator;
                    } else {
                        self.literal(") :tty ");
                        self.phase = .tty;
                    }
                },
                .arg_separator => {
                    self.phase = .arg;
                    if (self.arg_index == self.args.len) continue;
                    self.literal(" ");
                },
                .tty => {
                    self.quoted(self.tty_buffer[0..self.tty_len]);
                    self.phase = .env_open;
                },
                .env_open => {
                    self.literal(" :env (");
                    self.phase = .env_next;
                },
                .env_next => {
                    while (self.env_index < self.env.len) {
                        const line = std.mem.sliceTo(self.env[self.env_index], 0);
                        self.env_index += 1;
                        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                        self.env_name = line[0..equal];
                        self.env_value = line[equal + 1 ..];
                        self.literal(if (self.first_env) "(" else " (");
                        self.first_env = false;
                        self.phase = .env_name;
                        return true;
                    }
                    self.literal(self.size_buffer[0..self.size_len]);
                    self.phase = .finished;
                },
                .env_name => {
                    self.quoted(self.env_name);
                    self.phase = .env_space;
                },
                .env_space => {
                    self.literal(" ");
                    self.phase = .env_value;
                },
                .env_value => {
                    self.quoted(self.env_value);
                    self.phase = .env_close;
                },
                .env_close => {
                    self.literal(")");
                    self.phase = .env_next;
                },
                .finished => return false,
            }
            return true;
        }
    }
};

fn expectEncoded(
    encoder: *StartupEncoder,
    expected: []const u8,
    chunk_size: usize,
) !void {
    var chunk: [128]u8 = undefined;
    var offset: usize = 0;
    // Empty capacity must not advance the encoder.
    try std.testing.expectEqual(@as(usize, 0), encoder.encode(chunk[0..0]));
    while (!encoder.done()) {
        const count = encoder.encode(chunk[0..chunk_size]);
        try std.testing.expect(count > 0);
        try std.testing.expect(offset + count <= expected.len);
        try std.testing.expectEqualStrings(expected[offset .. offset + count], chunk[0..count]);
        offset += count;
    }
    try std.testing.expectEqual(expected.len, offset);
    try std.testing.expectEqual(@as(usize, 0), encoder.encode(&chunk));
}

test "startup encoder preserves wire format at every small chunk boundary" {
    const args = [_][*:0]const u8{ "tty-proxy", "", "a\"b\\c\n" };
    const env = [_][*:0]const u8{ "INVALID", "EMPTY=", "=unnamed", "A=a=b\"\\", "B=last" };
    const size = c.struct_winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 640,
        .ws_ypixel = 480,
    };
    const expected = "(:args (\"tty-proxy\" \"\" \"a\\\"b\\\\c\n\") :tty \"/dev/tty\\\"\\\\\"" ++
        " :env ((\"EMPTY\" \"\") (\"\" \"unnamed\") (\"A\" \"a=b\\\"\\\\\") (\"B\" \"last\"))" ++
        " :size (:rows 24 :cols 80 :xpixels 640 :ypixels 480))";
    for (1..65) |chunk_size| {
        var encoder = try StartupEncoder.initWithInfo(&args, &env, "/dev/tty\"\\", size);
        try expectEncoded(&encoder, expected, chunk_size);
    }
}

test "startup encoder handles empty argument and environment lists" {
    var encoder = try StartupEncoder.initWithInfo(&.{}, &.{}, "", .{});
    try expectEncoded(&encoder, "(:args () :tty \"\" :env () :size (:rows 0 :cols 0 :xpixels 0 :ypixels 0))", 1);
}

test "startup encoder streams a string larger than the proxy buffer" {
    const allocator = std.testing.allocator;
    const input = try allocator.allocSentinel(u8, 64 * 1024, 0);
    defer allocator.free(input);
    @memset(input, 'x');
    const args = [_][*:0]const u8{input.ptr};
    var encoder = try StartupEncoder.initWithInfo(&args, &.{}, "/dev/tty", .{});
    const expected = try std.fmt.allocPrint(allocator, "(:args (\"{s}\") :tty \"/dev/tty\" :env () :size (:rows 0 :cols 0 :xpixels 0 :ypixels 0))", .{input});
    defer allocator.free(expected);
    try expectEncoded(&encoder, expected, 127);
}
