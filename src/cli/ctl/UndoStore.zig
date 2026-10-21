//! On-disk undo stack for `ghostty +ctl`: one JSON file per change in a
//! directory per Ghostty instance (`$XDG_STATE_HOME/ghostty/ctl/<app id>/`),
//! newest = highest sequence number. Each entry is
//!
//!   {"version":1,"created":["0x…",…],"layout":<GetLayout before the change>}
//!
//! where `created` lists the surfaces the change spawned (filled in once the
//! ApplyLayout reply arrives).
const UndoStore = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const edit = @import("edit.zig");

/// Entries beyond this many are deleted, oldest first.
pub const max_entries = 20;

const ext = ".json";

io: std.Io,
dir: std.Io.Dir,

/// Open (creating if needed) the store at `path`.
pub fn open(io: std.Io, path: []const u8) !UndoStore {
    try std.Io.Dir.cwd().createDirPath(io, path);
    return .{
        .io = io,
        .dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }),
    };
}

pub fn close(self: *UndoStore) void {
    self.dir.close(self.io);
}

pub const Name = [20 + ext.len]u8;

/// Save `layout_json` (a GetLayout document) as the newest entry and trim
/// the stack to `max_entries`. Returns the entry's file name.
pub fn push(self: *UndoStore, alloc: Allocator, layout_json: []const u8) !Name {
    const seqs = try self.list(alloc);
    defer alloc.free(seqs);
    const next = if (seqs.len == 0) 1 else seqs[seqs.len - 1] + 1;

    var name: Name = undefined;
    _ = std.fmt.bufPrint(&name, "{d:0>20}" ++ ext, .{next}) catch unreachable;
    try self.write(alloc, &name, layout_json, &.{});

    // `seqs` doesn't contain the new entry yet.
    if (seqs.len + 1 > max_entries) {
        for (seqs[0 .. seqs.len + 1 - max_entries]) |seq| {
            var old: Name = undefined;
            _ = std.fmt.bufPrint(&old, "{d:0>20}" ++ ext, .{seq}) catch unreachable;
            try self.remove(&old);
        }
    }
    return name;
}

/// Rewrite entry `name` recording the surfaces the change created.
pub fn setCreated(
    self: *UndoStore,
    alloc: Allocator,
    name: []const u8,
    layout_json: []const u8,
    created: []const u64,
) !void {
    try self.write(alloc, name, layout_json, created);
}

pub const Entry = struct {
    name: Name,
    /// GetLayout document captured before the change.
    layout: std.json.Value,
    created: []const u64,
};

/// The newest entry, parsed into `arena`, or null if the stack is empty.
pub fn latest(self: *UndoStore, arena: Allocator) !?Entry {
    const seqs = try self.list(arena);
    if (seqs.len == 0) return null;

    var entry: Entry = undefined;
    _ = std.fmt.bufPrint(&entry.name, "{d:0>20}" ++ ext, .{seqs[seqs.len - 1]}) catch unreachable;
    const data = try self.dir.readFileAlloc(self.io, &entry.name, arena, .limited(64 * 1024 * 1024));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
    if (root != .object) return error.MalformedUndoEntry;
    entry.layout = root.object.get("layout") orelse return error.MalformedUndoEntry;

    var created: std.ArrayList(u64) = .empty;
    if (root.object.get("created")) |c| {
        if (c != .array) return error.MalformedUndoEntry;
        for (c.array.items) |v| {
            if (v != .string) return error.MalformedUndoEntry;
            try created.append(arena, edit.parseId(v.string) catch return error.MalformedUndoEntry);
        }
    }
    entry.created = created.items;
    return entry;
}

pub fn remove(self: *UndoStore, name: []const u8) !void {
    self.dir.deleteFile(self.io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Write an entry atomically (temp file + rename).
fn write(
    self: *UndoStore,
    alloc: Allocator,
    name: []const u8,
    layout_json: []const u8,
    created: []const u64,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"version\":1,\"created\":[");
    for (created, 0..) |id, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"0x{x:0>16}\"", .{id});
    }
    try w.writeAll("],\"layout\":");
    try w.writeAll(std.mem.trim(u8, layout_json, &std.ascii.whitespace));
    try w.writeAll("}\n");

    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".tmp-{s}", .{name});
    try self.dir.writeFile(self.io, .{ .sub_path = tmp, .data = out.written() });
    try std.Io.Dir.rename(self.dir, tmp, self.dir, name, self.io);
}

/// Sequence numbers of all entries, ascending. Caller frees.
fn list(self: *UndoStore, alloc: Allocator) ![]u64 {
    var seqs: std.ArrayList(u64) = .empty;
    errdefer seqs.deinit(alloc);
    var it = self.dir.iterate();
    while (try it.next(self.io)) |e| {
        if (e.kind != .file) continue;
        const stem = std.mem.cutSuffix(u8, e.name, ext) orelse continue;
        const seq = std.fmt.parseUnsigned(u64, stem, 10) catch continue;
        try seqs.append(alloc, seq);
    }
    std.mem.sort(u64, seqs.items, {}, std.sort.asc(u64));
    return seqs.toOwnedSlice(alloc);
}

test "ctl UndoStore: push, record, latest, trim" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var store: UndoStore = .{ .io = io, .dir = tmp.dir };
    try testing.expect(try store.latest(arena.allocator()) == null);

    const first = try store.push(testing.allocator, "{\"version\":1,\"windows\":[]}");
    const second = try store.push(testing.allocator, " {\"version\":1,\"n\":2} \n");
    try store.setCreated(testing.allocator, &second, "{\"version\":1,\"n\":2}", &.{ 0xa, 0xb });
    try testing.expectEqualStrings("00000000000000000001.json", &first);

    {
        const e = (try store.latest(arena.allocator())).?;
        try testing.expectEqualStrings(&second, &e.name);
        try testing.expectEqual(@as(i64, 2), e.layout.object.get("n").?.integer);
        try testing.expectEqualSlices(u64, &.{ 0xa, 0xb }, e.created);
    }

    try store.remove(&second);
    {
        const e = (try store.latest(arena.allocator())).?;
        try testing.expectEqualStrings(&first, &e.name);
        try testing.expectEqual(@as(usize, 0), e.created.len);
    }

    // Trimming keeps the newest `max_entries`.
    for (0..max_entries + 5) |_| _ = try store.push(testing.allocator, "{}");
    const seqs = try store.list(testing.allocator);
    defer testing.allocator.free(seqs);
    try testing.expectEqual(@as(usize, max_entries), seqs.len);
    try testing.expectEqual(@as(u64, 7), seqs[0]);
    try testing.expectEqual(@as(u64, 26), seqs[seqs.len - 1]);
}
