const std = @import("std");
const Allocator = std.mem.Allocator;
const CONFIG_ENV = "TTY_PROXY_CONFIG";

const c = std.c;

// Finds the socket path for this executable in the config file.
// The caller must free the returned path with allocator.
pub fn resolveSocket(
    environ: std.process.Environ,
    allocator: Allocator,
    argv0: []const u8,
) ![]const u8 {
    const path = try configPath(environ, allocator);
    defer allocator.free(path);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const fd = c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.ConfigReadFailed;
    defer _ = c.close(fd);

    // Read one extra byte to distinguish an exactly-at-limit file from an
    // oversized one without requiring file metadata (the path may be a FIFO).
    const max_size = 16 * 1024;
    const source = try allocator.alloc(u8, max_size + 1);
    defer allocator.free(source);
    var count: usize = 0;
    while (count < source.len) {
        const rc = c.read(fd, source[count..].ptr, source.len - count);
        if (rc < 0) {
            if (c.errno(rc) == .INTR) continue;
            return error.ConfigReadFailed;
        }
        if (rc == 0) break;
        count += @intCast(rc);
    }
    if (count > max_size) return error.StreamTooLong;

    return findSocket(allocator, argv0, source[0..count]);
}

// Config lookup prefers an explicit override and otherwise falls back to the
// standard per-user config location.
fn configPath(environ: std.process.Environ, allocator: Allocator) ![]const u8 {
    if (environ.getPosix(CONFIG_ENV)) |path| return allocator.dupe(u8, path);

    const home = environ.getPosix("HOME") orelse
        return error.EnvironmentVariableNotFound;

    return std.fs.path.join(
        allocator,
        &.{ home, ".config/tty-proxy/config" },
    );
}

// Parses the plain-text config and selects the best matching socket entry:
// exact argv[0] first, then basename.
fn findSocket(
    allocator: Allocator,
    argv0: []const u8,
    source: []const u8,
) ![]const u8 {
    const basename = std.fs.path.basename(argv0);

    var basename_socket: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#')
            continue;

        const equal_idx = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidConfigFormat;

        const name = std.mem.trim(u8, line[0..equal_idx], " \t");
        const value = std.mem.trim(u8, line[equal_idx + 1 ..], " \t");

        if (name.len == 0 or value.len == 0) return error.InvalidConfigFormat;

        const socket = parseSocketValue(value) orelse continue;

        if (std.mem.eql(u8, name, argv0)) {
            return allocator.dupe(u8, socket);
        }

        if (basename_socket == null and std.mem.eql(u8, name, basename)) {
            basename_socket = socket;
        }
    }

    if (basename_socket) |socket| {
        return allocator.dupe(u8, socket);
    }

    return error.NoPeerSocketConfigured;
}

// Only socket: targets are actionable here; other target syntaxes are ignored.
fn parseSocketValue(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, "socket:")) return null;

    const socket = std.mem.trim(u8, value["socket:".len..], " \t");

    if (socket.len == 0) return null;

    return socket;
}

test "resolve socket prefers exact over basename and ignores command values" {
    const allocator = std.testing.allocator;
    const input =
        \\# comments and blank lines are ignored
        \\
        \\tty-proxy = socket:/tmp/base.sock
        \\/usr/local/bin/tty-proxy = sbcl --load ttt.lisp
        \\/usr/bin/tty-proxy = socket:/tmp/exact.sock
    ;

    const exact = try findSocket(
        allocator,
        "/usr/bin/tty-proxy",
        input,
    );
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("/tmp/exact.sock", exact);

    const basename = try findSocket(
        allocator,
        "/opt/bin/tty-proxy",
        input,
    );
    defer allocator.free(basename);
    try std.testing.expectEqualStrings("/tmp/base.sock", basename);
}

test "resolve socket reports missing when only command target exists" {
    const allocator = std.testing.allocator;
    const input =
        \\tty-proxy = sbcl --load ttt.lisp
    ;

    try std.testing.expectError(
        error.NoPeerSocketConfigured,
        findSocket(allocator, "tty-proxy", input),
    );
}

test "resolve socket fails when allocator is too small" {
    var backing: [8]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const allocator = fba.allocator();
    const input =
        \\tty-proxy = socket:/tmp/very-long.sock
    ;

    try std.testing.expectError(
        error.OutOfMemory,
        findSocket(allocator, "tty-proxy", input),
    );
}
