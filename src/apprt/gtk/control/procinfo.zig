//! Process details from Linux `/proc` for the GetLayout snapshot: a
//! process's name, command line and working directory. Every lookup returns
//! null when the information is unavailable (process exited, permission
//! denied, not Linux).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../../../global.zig");

const has_proc = builtin.target.os.tag == .linux;

/// Buffer large enough for any `/proc/<pid>/<file>` path we build.
const PathBuf = [64]u8;

/// Buffer size for `comm`; the kernel limits it to 16 bytes (TASK_COMM_LEN)
/// including the newline.
pub const comm_buf_len = 64;

/// The process name (`/proc/<pid>/comm`) without the trailing newline,
/// stored in `buf`.
pub fn comm(buf: *[comm_buf_len]u8, pid: u64) ?[]const u8 {
    if (!has_proc or pid == 0) return null;
    var path_buf: PathBuf = undefined;
    const path = procPath(&path_buf, pid, "comm");
    const data = std.Io.Dir.cwd().readFile(global.io(), path, buf) catch return null;
    const name = std.mem.trimEnd(u8, data, "\n");
    if (name.len == 0) return null;
    return name;
}

/// The raw command line (`/proc/<pid>/cmdline`): arguments separated by NUL
/// bytes. Iterate it with `args`. Caller owns the returned memory. Returns
/// null for processes without a command line (kernel threads, zombies).
pub fn cmdline(alloc: Allocator, pid: u64) Allocator.Error!?[]u8 {
    if (!has_proc or pid == 0) return null;
    var path_buf: PathBuf = undefined;
    const path = procPath(&path_buf, pid, "cmdline");
    const io = global.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    // /proc files report a size of 0, so read in streaming mode until EOF
    // (Dir.readFileAlloc trusts the size and returns nothing).
    var reader = file.readerStreaming(io, &.{});
    const data = reader.interface.allocRemaining(alloc, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed, error.StreamTooLong => return null,
    };
    if (data.len == 0) {
        alloc.free(data);
        return null;
    }
    return data;
}

/// Iterate the arguments of a raw `cmdline` result.
pub fn args(raw: []const u8) std.mem.SplitIterator(u8, .scalar) {
    // The kernel terminates every argument (including the last) with NUL.
    const trimmed = if (std.mem.endsWith(u8, raw, "\x00")) raw[0 .. raw.len - 1] else raw;
    return std.mem.splitScalar(u8, trimmed, 0);
}

/// The working directory (`/proc/<pid>/cwd`) stored in `buf`.
pub fn cwd(buf: *[std.fs.max_path_bytes]u8, pid: u64) ?[]const u8 {
    if (!has_proc or pid == 0) return null;
    var path_buf: PathBuf = undefined;
    const path = procPath(&path_buf, pid, "cwd");
    const n = std.Io.Dir.cwd().readLink(global.io(), path, buf) catch return null;
    return buf[0..n];
}

fn procPath(buf: *PathBuf, pid: u64, file: []const u8) []const u8 {
    // A u64 pid and our short file names always fit.
    return std.fmt.bufPrint(buf, "/proc/{d}/{s}", .{ pid, file }) catch unreachable;
}

fn selfPid() u64 {
    return @intCast(std.os.linux.getpid());
}

test "procinfo: comm of self" {
    if (!has_proc) return error.SkipZigTest;
    const testing = std.testing;

    var buf: [comm_buf_len]u8 = undefined;
    const name = comm(&buf, selfPid()).?;
    try testing.expect(name.len > 0);
    try testing.expect(name.len < 16);
    try testing.expect(std.mem.indexOfScalar(u8, name, '\n') == null);

    // The kernel truncates comm to the first 15 bytes of the executable's
    // basename, so it must be a prefix of argv[0]'s basename.
    const raw = (try cmdline(testing.allocator, selfPid())).?;
    defer testing.allocator.free(raw);
    var it = args(raw);
    const argv0 = it.next().?;
    try testing.expect(std.mem.startsWith(u8, std.fs.path.basename(argv0), name));
}

test "procinfo: cmdline of self" {
    if (!has_proc) return error.SkipZigTest;
    const testing = std.testing;

    const raw = (try cmdline(testing.allocator, selfPid())).?;
    defer testing.allocator.free(raw);
    try testing.expect(raw[raw.len - 1] == 0);

    var n: usize = 0;
    var it = args(raw);
    while (it.next()) |arg| : (n += 1) {
        try testing.expect(std.mem.indexOfScalar(u8, arg, 0) == null);
    }
    try testing.expectEqual(std.mem.count(u8, raw, "\x00"), n);
}

test "procinfo: cwd of self" {
    if (!has_proc) return error.SkipZigTest;
    const testing = std.testing;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = cwd(&buf, selfPid()).?;

    const expected = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, dir);
}

test "procinfo: missing process" {
    const testing = std.testing;

    // pid 0 is never a user process; the max pid is far above pid_max.
    for ([_]u64{ 0, std.math.maxInt(u32) }) |pid| {
        var comm_buf: [comm_buf_len]u8 = undefined;
        try testing.expect(comm(&comm_buf, pid) == null);
        try testing.expect(try cmdline(testing.allocator, pid) == null);
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        try testing.expect(cwd(&cwd_buf, pid) == null);
    }
}

test "procinfo: args" {
    const testing = std.testing;

    var it = args("a\x00bc\x00\x00d\x00");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("bc", it.next().?);
    try testing.expectEqualStrings("", it.next().?);
    try testing.expectEqualStrings("d", it.next().?);
    try testing.expect(it.next() == null);

    // Processes that rewrite their title may drop the final NUL.
    it = args("x y");
    try testing.expectEqualStrings("x y", it.next().?);
    try testing.expect(it.next() == null);
}
