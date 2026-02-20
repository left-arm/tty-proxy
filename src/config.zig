const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;
const CONFIG_ENV = "TTY_PROXY_CONFIG";

// Resolves the Unix-socket target for the current executable name from the
// runtime config file.
pub fn resolveSocket(
    allocator: Allocator,
    argv0: []const u8,
) ![]const u8 {
    const path = try configPath(allocator);
    defer allocator.free(path);

    const source = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        16 * 1024,
        1024,
        std.mem.Alignment.of(u8),
        0,
    );
    defer allocator.free(source);

    return resolveSocketFromSource(allocator, argv0, source);
}

// Config lookup prefers an explicit override and otherwise falls back to the
// standard per-user config location.
fn configPath(allocator: Allocator) ![]const u8 {
    if (posix.getenv(CONFIG_ENV)) |path| {
        return allocator.dupe(u8, path);
    }

    const home = posix.getenv("HOME") orelse
        return error.EnvironmentVariableNotFound;

    return try std.fs.path.join(
        allocator,
        &.{ home, ".config/tty-proxy/config" },
    );
}

// Parses the plain-text config and selects the best matching socket entry:
// exact argv[0] first, then basename.
fn resolveSocketFromSource(
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

// Copies a parsed socket path into a caller-provided buffer.
fn copySocketPath(socket_out: []u8, socket: []const u8) ![]const u8 {
    if (socket.len > socket_out.len) return error.BufferTooSmall;
    @memcpy(socket_out[0..socket.len], socket);
    return socket_out[0..socket.len];
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

    const exact = try resolveSocketFromSource(
        allocator,
        "/usr/bin/tty-proxy",
        input,
    );
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("/tmp/exact.sock", exact);

    const basename = try resolveSocketFromSource(
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
        resolveSocketFromSource(allocator, "tty-proxy", input),
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
        resolveSocketFromSource(allocator, "tty-proxy", input),
    );
}
