//! Pure edits over GetLayout / ApplyLayout JSON documents (`std.json.Value`)
//! used by `ghostty +ctl` to implement its convenience operations
//! client-side as GetLayout → edit → ApplyLayout. See
//! `src/apprt/gtk/control/spec.zig` for the document format.
//!
//! All functions mutate the document in place and allocate with an arena:
//! replaced values are simply abandoned.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub const Error = Allocator.Error || error{
    /// The document doesn't have the expected GetLayout/spec shape.
    MalformedLayout,
    /// A surface id isn't in any (non quick-terminal) window.
    SurfaceNotFound,
    /// A window id isn't in the layout (or is a quick-terminal window).
    WindowNotFound,
    /// An operation needs two different surfaces.
    SameSurface,
    /// No ancestor split with the requested layout.
    NoSplit,
    /// Ratio outside (0, 1).
    InvalidRatio,
    /// Undo: no saved surface still exists.
    NothingToRestore,
};

pub const Edge = enum { left, right, up, down };
pub const Layout = enum { horizontal, vertical };

/// Parse a surface id: `0x…` hex (as in GHOSTTY_SURFACE_ID) or decimal.
pub fn parseId(s: []const u8) error{InvalidId}!u64 {
    const trimmed = std.mem.trim(u8, s, &std.ascii.whitespace);
    const id = std.fmt.parseUnsigned(u64, trimmed, 0) catch return error.InvalidId;
    if (id == 0) return error.InvalidId;
    return id;
}

/// Format a surface id the way GetLayout and GHOSTTY_SURFACE_ID do.
pub fn formatId(alloc: Allocator, id: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "0x{x:0>16}", .{id});
}

/// Turn a GetLayout document into an ApplyLayout spec over the same windows:
/// quick-terminal windows (which the server never touches) are dropped and
/// the document is normalized.
pub fn toSpec(alloc: Allocator, doc: *Value) Error!void {
    const windows = try windowsOf(doc);
    var i: usize = 0;
    while (i < windows.items.len) {
        if (isQuickTerminal(windows.items[i])) {
            _ = windows.orderedRemove(i);
        } else i += 1;
    }
    try normalize(alloc, doc);
}

/// Move surface `src` next to `tgt`, on `edge` of it (a new 50/50 split
/// replaces `tgt`).
pub fn move(alloc: Allocator, doc: *Value, src: u64, tgt: u64, edge: Edge) Error!void {
    if (src == tgt) return error.SameSurface;
    if (try locate(alloc, doc, tgt) == null) return error.SurfaceNotFound;
    const src_loc = try locate(alloc, doc, src) orelse return error.SurfaceNotFound;
    const leaf = try detach(doc, src_loc);

    // Re-locate: detaching may have moved the target's slot.
    const tgt_loc = (try locate(alloc, doc, tgt)).?;
    const slot = tgt_loc.leaf();
    const target = slot.*;
    slot.* = switch (edge) {
        .left => try makeSplit(alloc, .horizontal, 0.5, leaf, target),
        .right => try makeSplit(alloc, .horizontal, 0.5, target, leaf),
        .up => try makeSplit(alloc, .vertical, 0.5, leaf, target),
        .down => try makeSplit(alloc, .vertical, 0.5, target, leaf),
    };
    try normalize(alloc, doc);
}

/// Exchange the positions of surfaces `a` and `b` (any tabs/windows).
pub fn swap(alloc: Allocator, doc: *Value, a: u64, b: u64) Error!void {
    if (a == b) return error.SameSurface;
    const la = try locate(alloc, doc, a) orelse return error.SurfaceNotFound;
    const lb = try locate(alloc, doc, b) orelse return error.SurfaceNotFound;
    const tmp = la.leaf().*;
    la.leaf().* = lb.leaf().*;
    lb.leaf().* = tmp;

    // Across tabs, a zoom follows the slot: the surface that took the zoomed
    // surface's place becomes zoomed.
    if (la.win != lb.win or la.tab != lb.tab) {
        const windows = try windowsOf(doc);
        const ta = &(try tabsOf(&windows.items[la.win])).items[la.tab];
        const tb = &(try tabsOf(&windows.items[lb.win])).items[lb.tab];
        if (zoomedId(ta.*) == a) try ta.object.put(alloc, "zoomed", try idValue(alloc, b));
        if (zoomedId(tb.*) == b) try tb.object.put(alloc, "zoomed", try idValue(alloc, a));
    }
    try normalize(alloc, doc);
}

pub const TabTarget = union(enum) {
    /// The window currently containing the surface.
    current,
    /// An existing window id.
    window: i64,
    /// A new window.
    new_window,
};

/// Move surface `src` into a tab of its own in `target`, at tab index
/// `position` (default: last; clamped).
pub fn toTab(
    alloc: Allocator,
    doc: *Value,
    src: u64,
    target: TabTarget,
    position: ?usize,
) Error!void {
    const loc = try locate(alloc, doc, src) orelse return error.SurfaceNotFound;
    const windows = try windowsOf(doc);
    const win_index: ?usize = switch (target) {
        .current => loc.win,
        .window => |id| findWindow(windows.items, id) orelse return error.WindowNotFound,
        .new_window => null,
    };

    // A lone surface moving within its window carries the tab's selection.
    const was_selected = loc.path.len == 1 and win_index == loc.win and
        selectedTab(windows.items[loc.win]) == loc.tab;

    // Detaching never removes windows (normalize does), so indices hold.
    const leaf = try detach(doc, loc);
    var tab: ObjectMap = .empty;
    try tab.put(alloc, "tree", leaf);

    if (win_index) |wi| {
        const win = &windows.items[wi];
        const tabs = try tabsOf(win);
        const pos = @min(position orelse tabs.items.len, tabs.items.len);
        try tabs.insert(pos, .{ .object = tab });
        if (was_selected) {
            try setSelectedTab(alloc, win, pos);
        } else if (selectedTab(win.*)) |sel| {
            if (sel >= pos) try setSelectedTab(alloc, win, sel + 1);
        }
    } else {
        var tabs: json.Array = .init(alloc);
        try tabs.append(.{ .object = tab });
        var win: ObjectMap = .empty;
        try win.put(alloc, "selected_tab", .{ .integer = 0 });
        try win.put(alloc, "tabs", .{ .array = tabs });
        try windows.append(.{ .object = win });
    }
    try normalize(alloc, doc);
}

/// Set the ratio of the nearest split with `layout` that contains `id`.
pub fn setRatio(alloc: Allocator, doc: *Value, id: u64, layout: Layout, ratio: f64) Error!void {
    if (!(ratio > 0 and ratio < 1)) return error.InvalidRatio;
    const loc = try locate(alloc, doc, id) orelse return error.SurfaceNotFound;
    var i = loc.path.len - 1;
    while (i > 0) {
        i -= 1;
        const node = loc.path[i];
        const l = node.object.get("layout") orelse return error.MalformedLayout;
        if (l != .string) return error.MalformedLayout;
        if (std.mem.eql(u8, l.string, @tagName(layout))) {
            try node.object.put(alloc, "ratio", .{ .float = ratio });
            return;
        }
    }
    return error.NoSplit;
}

pub const UndoPlan = struct {
    /// The spec to apply (`saved`, edited in place).
    spec: *Value,
    /// Live surfaces the spec doesn't place (all created by the undone
    /// change unless `refused` is non-empty).
    unplaced: []const u64,
    /// Unplaced surfaces that the undone change did NOT create. Non-empty
    /// means the undo must be refused.
    refused: []const u64,

    /// Whether ApplyLayout must be called with allow_close.
    pub fn allowClose(self: UndoPlan) bool {
        return self.unplaced.len > 0;
    }
};

/// Plan restoring `saved` (a GetLayout document from before a change) over
/// `current` (the live GetLayout document). Surfaces that no longer exist
/// are pruned from `saved`, windows that no longer exist become new
/// windows, and focus is restored if the saved focused surface survives.
/// Live surfaces left unplaced may only be ones in `created` (the surfaces
/// the undone change spawned); anything else is reported in `refused`.
pub fn planUndo(
    alloc: Allocator,
    current: *Value,
    saved: *Value,
    created: []const u64,
) Error!UndoPlan {
    try toSpec(alloc, current);
    const live = try collectIds(alloc, current);
    var live_windows: std.ArrayList(i64) = .empty;
    for ((try windowsOf(current)).items) |w| {
        if (windowId(w)) |id| try live_windows.append(alloc, id);
    }

    try toSpec(alloc, saved);
    for (try collectIds(alloc, saved)) |id| {
        if (contains(live, id)) continue;
        const loc = (try locate(alloc, saved, id)).?;
        _ = try detach(saved, loc);
    }
    for ((try windowsOf(saved)).items) |*w| {
        const id = windowId(w.*) orelse continue;
        if (std.mem.indexOfScalar(i64, live_windows.items, id) == null) {
            _ = w.object.orderedRemove("id");
        }
    }
    try normalize(alloc, saved);
    if ((try windowsOf(saved)).items.len == 0) return error.NothingToRestore;

    const placed = try collectIds(alloc, saved);
    var unplaced: std.ArrayList(u64) = .empty;
    var refused: std.ArrayList(u64) = .empty;
    for (live) |id| {
        if (contains(placed, id)) continue;
        try unplaced.append(alloc, id);
        if (!contains(created, id)) try refused.append(alloc, id);
    }

    // Restore the focus the snapshot had, when that surface survives.
    if (focusedId(saved.*)) |id| {
        if (contains(placed, id)) try saved.object.put(alloc, "focus", try idValue(alloc, id));
    }

    return .{ .spec = saved, .unplaced = unplaced.items, .refused = refused.items };
}

/// The surface ids reported as created in an ApplyLayout result
/// (`{"created":{"name":"0x…"|null,…},…}`); nulls are skipped.
pub fn createdIds(alloc: Allocator, result: Value) Error![]const u64 {
    if (result != .object) return error.MalformedLayout;
    const created = result.object.get("created") orelse return &.{};
    if (created != .object) return error.MalformedLayout;
    var ids: std.ArrayList(u64) = .empty;
    for (created.object.values()) |v| {
        if (v != .string) continue;
        try ids.append(alloc, parseId(v.string) catch return error.MalformedLayout);
    }
    return ids.items;
}

/// Every surface id in the document's windows, in document order.
pub fn collectIds(alloc: Allocator, doc: *Value) Error![]u64 {
    var ids: std.ArrayList(u64) = .empty;
    for ((try windowsOf(doc)).items) |*w| {
        for ((try tabsOf(w)).items) |*t| try collectNode(alloc, (try treeOf(t)).*, &ids);
    }
    return ids.items;
}

fn collectNode(alloc: Allocator, node: Value, ids: *std.ArrayList(u64)) Error!void {
    if (isLeaf(node)) {
        if (leafId(node)) |id| try ids.append(alloc, id);
        return;
    }
    if (node != .object) return error.MalformedLayout;
    for ([_][]const u8{ "left", "right" }) |key| {
        try collectNode(alloc, node.object.get(key) orelse return error.MalformedLayout, ids);
    }
}

/// Where a surface lives: window/tab index and the chain of node slots
/// from the tab's "tree" down to the leaf. Valid until the next mutation.
const Loc = struct {
    win: usize,
    tab: usize,
    path: []*Value,

    fn leaf(self: Loc) *Value {
        return self.path[self.path.len - 1];
    }
};

fn locate(alloc: Allocator, doc: *Value, id: u64) Error!?Loc {
    var path: std.ArrayList(*Value) = .empty;
    for ((try windowsOf(doc)).items, 0..) |*w, wi| {
        for ((try tabsOf(w)).items, 0..) |*t, ti| {
            path.clearRetainingCapacity();
            if (try search(alloc, try treeOf(t), id, &path)) {
                return .{ .win = wi, .tab = ti, .path = path.items };
            }
        }
    }
    return null;
}

fn search(alloc: Allocator, slot: *Value, id: u64, path: *std.ArrayList(*Value)) Error!bool {
    try path.append(alloc, slot);
    if (isLeaf(slot.*)) {
        if (leafId(slot.*) == id) return true;
    } else {
        if (slot.* != .object) return error.MalformedLayout;
        for ([_][]const u8{ "left", "right" }) |key| {
            const child = slot.object.getPtr(key) orelse return error.MalformedLayout;
            if (try search(alloc, child, id, path)) return true;
        }
    }
    _ = path.pop();
    return false;
}

/// Remove the leaf at `loc`, returning it. Its parent split is replaced by
/// the sibling; a tab whose root it was is removed. Windows left without
/// tabs are removed later by `normalize`.
fn detach(doc: *Value, loc: Loc) Error!Value {
    const leaf = loc.leaf().*;
    if (loc.path.len == 1) {
        const win = &(try windowsOf(doc)).items[loc.win];
        _ = (try tabsOf(win)).orderedRemove(loc.tab);
        if (selectedTab(win.*)) |sel| {
            if (sel > loc.tab) win.object.getPtr("selected_tab").?.* = .{ .integer = @intCast(sel - 1) };
        }
        return leaf;
    }
    const parent = loc.path[loc.path.len - 2];
    const left = parent.object.getPtr("left").?;
    const sibling = if (left == loc.leaf()) parent.object.get("right").? else left.*;
    parent.* = sibling;
    return leaf;
}

/// Drop zoom refs that aren't leaves of their tab, drop windows without
/// tabs and clamp selected_tab.
fn normalize(alloc: Allocator, doc: *Value) Error!void {
    const windows = try windowsOf(doc);
    var wi: usize = 0;
    while (wi < windows.items.len) {
        const win = &windows.items[wi];
        const tabs = try tabsOf(win);
        if (tabs.items.len == 0) {
            _ = windows.orderedRemove(wi);
            continue;
        }
        for (tabs.items) |*t| {
            const z = zoomedId(t.*) orelse continue;
            var ids: std.ArrayList(u64) = .empty;
            try collectNode(alloc, (try treeOf(t)).*, &ids);
            if (!contains(ids.items, z)) try t.object.put(alloc, "zoomed", .null);
        }
        if (selectedTab(win.*)) |sel| {
            if (sel >= tabs.items.len) try setSelectedTab(alloc, win, tabs.items.len - 1);
        }
        wi += 1;
    }
}

fn makeSplit(alloc: Allocator, layout: Layout, ratio: f64, left: Value, right: Value) Allocator.Error!Value {
    var obj: ObjectMap = .empty;
    try obj.put(alloc, "type", .{ .string = "split" });
    try obj.put(alloc, "layout", .{ .string = @tagName(layout) });
    try obj.put(alloc, "ratio", .{ .float = ratio });
    try obj.put(alloc, "left", left);
    try obj.put(alloc, "right", right);
    return .{ .object = obj };
}

fn idValue(alloc: Allocator, id: u64) Allocator.Error!Value {
    return .{ .string = try formatId(alloc, id) };
}

fn windowsOf(doc: *Value) Error!*json.Array {
    if (doc.* != .object) return error.MalformedLayout;
    const w = doc.object.getPtr("windows") orelse return error.MalformedLayout;
    if (w.* != .array) return error.MalformedLayout;
    return &w.array;
}

fn tabsOf(win: *Value) Error!*json.Array {
    if (win.* != .object) return error.MalformedLayout;
    const t = win.object.getPtr("tabs") orelse return error.MalformedLayout;
    if (t.* != .array) return error.MalformedLayout;
    return &t.array;
}

fn treeOf(tab: *Value) Error!*Value {
    if (tab.* != .object) return error.MalformedLayout;
    return tab.object.getPtr("tree") orelse error.MalformedLayout;
}

fn isQuickTerminal(win: Value) bool {
    if (win != .object) return false;
    const q = win.object.get("quick_terminal") orelse return false;
    return q == .bool and q.bool;
}

fn windowId(win: Value) ?i64 {
    if (win != .object) return null;
    const id = win.object.get("id") orelse return null;
    return if (id == .integer) id.integer else null;
}

fn findWindow(windows: []const Value, id: i64) ?usize {
    for (windows, 0..) |w, i| if (windowId(w) == id) return i;
    return null;
}

fn selectedTab(win: Value) ?usize {
    const sel = win.object.get("selected_tab") orelse return null;
    if (sel != .integer or sel.integer < 0) return null;
    return @intCast(sel.integer);
}

fn setSelectedTab(alloc: Allocator, win: *Value, sel: usize) Allocator.Error!void {
    try win.object.put(alloc, "selected_tab", .{ .integer = @intCast(sel) });
}

fn focusedId(doc: Value) ?u64 {
    const f = doc.object.get("focused_surface") orelse return null;
    if (f != .string) return null;
    return parseId(f.string) catch null;
}

fn zoomedId(tab: Value) ?u64 {
    if (tab != .object) return null;
    const z = tab.object.get("zoomed") orelse return null;
    if (z != .string) return null;
    return parseId(z.string) catch null;
}

fn isLeaf(node: Value) bool {
    if (node != .object) return false;
    const t = node.object.get("type") orelse return false;
    return t == .string and std.mem.eql(u8, t.string, "surface");
}

fn leafId(node: Value) ?u64 {
    if (!isLeaf(node)) return null;
    const id = node.object.get("id") orelse return null;
    if (id != .string) return null;
    return parseId(id.string) catch null;
}

fn contains(ids: []const u64, id: u64) bool {
    return std.mem.indexOfScalar(u64, ids, id) != null;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

/// A compact rendering of a document for assertions:
/// `W<id|new>/<selected>[<tab>|<tab>] …`, tabs as `(h0.5 1 2)` or `1`, `*N`
/// suffix for a zoomed tab, `focus=N` if set.
fn describe(alloc: Allocator, doc: *Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    for ((try windowsOf(doc)).items, 0..) |*win, i| {
        if (i > 0) try w.writeByte(' ');
        if (windowId(win.*)) |id| try w.print("W{d}", .{id}) else try w.writeAll("Wnew");
        if (selectedTab(win.*)) |sel| try w.print("/{d}", .{sel});
        try w.writeByte('[');
        for ((try tabsOf(win)).items, 0..) |*t, ti| {
            if (ti > 0) try w.writeByte('|');
            try describeNode(w, (try treeOf(t)).*);
            if (zoomedId(t.*)) |z| try w.print("*{x}", .{z});
        }
        try w.writeByte(']');
    }
    if (doc.object.get("focus")) |f| try w.print(" focus={x}", .{try parseId(f.string)});
    return out.toOwnedSlice();
}

fn describeNode(w: *std.Io.Writer, node: Value) !void {
    if (leafId(node)) |id| return w.print("{x}", .{id});
    const l = node.object.get("layout").?.string;
    const r = node.object.get("ratio").?;
    try w.print("({c}{d} ", .{ l[0], switch (r) {
        .float => |f| f,
        .integer => |n| @as(f64, @floatFromInt(n)),
        else => unreachable,
    } });
    try describeNode(w, node.object.get("left").?);
    try w.writeByte(' ');
    try describeNode(w, node.object.get("right").?);
    try w.writeByte(')');
}

/// Two windows plus a quick terminal:
///   W1 (selected tab 1): tab0 = (h 1 (v 2 3)), tab1 = 4
///   W2: tab0 = 5 zoomed on 5
///   W9 (quick terminal): 9
const fixture =
    \\{"version":1,"focused_surface":"0x0000000000000002","windows":[
    \\ {"id":1,"active":true,"quick_terminal":false,"title":"a","selected_tab":1,"tabs":[
    \\  {"index":0,"selected":false,"title":"t","zoomed":null,"tree":
    \\   {"type":"split","layout":"horizontal","ratio":0.25,
    \\    "left":{"type":"surface","id":"0x0000000000000001","pid":10,"title":"x","cwd":null,"focused":false},
    \\    "right":{"type":"split","layout":"vertical","ratio":0.5,
    \\      "left":{"type":"surface","id":"0x0000000000000002","focused":true},
    \\      "right":{"type":"surface","id":"0x0000000000000003","focused":false}}}},
    \\  {"index":1,"selected":true,"zoomed":null,"tree":{"type":"surface","id":"0x0000000000000004"}}]},
    \\ {"id":2,"active":false,"quick_terminal":false,"selected_tab":0,"tabs":[
    \\  {"index":0,"selected":true,"zoomed":"0x0000000000000005","tree":{"type":"surface","id":"0x0000000000000005"}}]},
    \\ {"id":9,"active":false,"quick_terminal":true,"selected_tab":0,"tabs":[
    \\  {"index":0,"selected":true,"zoomed":null,"tree":{"type":"surface","id":"0x0000000000000009"}}]}]}
;

fn testDoc(alloc: Allocator) !Value {
    var doc = try json.parseFromSliceLeaky(Value, alloc, fixture, .{});
    try toSpec(alloc, &doc);
    return doc;
}

fn expectDoc(alloc: Allocator, doc: *Value, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, try describe(alloc, doc));
    // The edited document must still serialize.
    _ = try json.Stringify.valueAlloc(alloc, doc.*, .{});
}

test "ctl edit: parseId" {
    try testing.expectEqual(@as(u64, 0xabc), try parseId("0x0000000000000abc"));
    try testing.expectEqual(@as(u64, 42), try parseId(" 42 "));
    try testing.expectError(error.InvalidId, parseId("0x0"));
    try testing.expectError(error.InvalidId, parseId("zz"));
    const s = try formatId(testing.allocator, 0xff);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("0x00000000000000ff", s);
}

test "ctl edit: toSpec drops quick terminal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = try testDoc(alloc);
    try expectDoc(alloc, &doc, "W1/1[(h0.25 1 (v0.5 2 3))|4] W2/0[5*5]");
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, try collectIds(alloc, &doc));
}

test "ctl edit: move within a tab" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = try testDoc(alloc);
    try move(alloc, &doc, 3, 1, .up);
    try expectDoc(alloc, &doc, "W1/1[(h0.25 (v0.5 3 1) 2)|4] W2/0[5*5]");
}

test "ctl edit: move across windows empties source" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = try testDoc(alloc);
    // Moving 5 out of W2 empties it: the window disappears from the spec.
    try move(alloc, &doc, 5, 4, .right);
    try expectDoc(alloc, &doc, "W1/1[(h0.25 1 (v0.5 2 3))|(h0.5 4 5)]");
    // Moving the last surface of a tab removes the tab and fixes selection.
    var doc2 = try testDoc(alloc);
    try move(alloc, &doc2, 4, 2, .down);
    try expectDoc(alloc, &doc2, "W1/0[(h0.25 1 (v0.5 (v0.5 2 4) 3))] W2/0[5*5]");
}

test "ctl edit: move errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = try testDoc(alloc);
    try testing.expectError(error.SameSurface, move(alloc, &doc, 1, 1, .left));
    try testing.expectError(error.SurfaceNotFound, move(alloc, &doc, 1, 0x77, .left));
    try testing.expectError(error.SurfaceNotFound, move(alloc, &doc, 9, 1, .left));
    try expectDoc(alloc, &doc, "W1/1[(h0.25 1 (v0.5 2 3))|4] W2/0[5*5]");
}

test "ctl edit: swap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = try testDoc(alloc);
    try swap(alloc, &doc, 1, 3);
    try expectDoc(alloc, &doc, "W1/1[(h0.25 3 (v0.5 2 1))|4] W2/0[5*5]");
    // Across windows the zoom follows the slot.
    try swap(alloc, &doc, 5, 2);
    try expectDoc(alloc, &doc, "W1/1[(h0.25 3 (v0.5 5 1))|4] W2/0[2*2]");
    try testing.expectError(error.SameSurface, swap(alloc, &doc, 4, 4));
    try testing.expectError(error.SurfaceNotFound, swap(alloc, &doc, 4, 9));
}

test "ctl edit: toTab" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        // Same window, appended; the selected tab stays selected.
        var doc = try testDoc(alloc);
        try toTab(alloc, &doc, 2, .current, null);
        try expectDoc(alloc, &doc, "W1/1[(h0.25 1 3)|4|2] W2/0[5*5]");
    }
    {
        // Inserted before the selected tab: selection index shifts.
        var doc = try testDoc(alloc);
        try toTab(alloc, &doc, 3, .current, 0);
        try expectDoc(alloc, &doc, "W1/2[3|(h0.25 1 2)|4] W2/0[5*5]");
    }
    {
        // Other window; its only surface leaving would remove it.
        var doc = try testDoc(alloc);
        try toTab(alloc, &doc, 5, .{ .window = 1 }, 99);
        try expectDoc(alloc, &doc, "W1/1[(h0.25 1 (v0.5 2 3))|4|5]");
    }
    {
        // Lone surface re-positioned within its own window.
        var doc = try testDoc(alloc);
        try toTab(alloc, &doc, 4, .current, 0);
        try expectDoc(alloc, &doc, "W1/0[4|(h0.25 1 (v0.5 2 3))] W2/0[5*5]");
    }
    {
        var doc = try testDoc(alloc);
        try toTab(alloc, &doc, 1, .new_window, null);
        try expectDoc(alloc, &doc, "W1/1[(v0.5 2 3)|4] W2/0[5*5] Wnew/0[1]");
    }
    {
        var doc = try testDoc(alloc);
        try testing.expectError(error.WindowNotFound, toTab(alloc, &doc, 1, .{ .window = 9 }, null));
        try testing.expectError(error.SurfaceNotFound, toTab(alloc, &doc, 9, .current, null));
    }
}

test "ctl edit: setRatio" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc = try testDoc(alloc);
    try setRatio(alloc, &doc, 3, .vertical, 0.75);
    try setRatio(alloc, &doc, 3, .horizontal, 0.5);
    try expectDoc(alloc, &doc, "W1/1[(h0.5 1 (v0.75 2 3))|4] W2/0[5*5]");
    try setRatio(alloc, &doc, 1, .horizontal, 0.125);
    try expectDoc(alloc, &doc, "W1/1[(h0.125 1 (v0.75 2 3))|4] W2/0[5*5]");
    try testing.expectError(error.NoSplit, setRatio(alloc, &doc, 1, .vertical, 0.5));
    try testing.expectError(error.NoSplit, setRatio(alloc, &doc, 4, .horizontal, 0.5));
    try testing.expectError(error.InvalidRatio, setRatio(alloc, &doc, 3, .vertical, 1));
    try testing.expectError(error.InvalidRatio, setRatio(alloc, &doc, 3, .vertical, 0));
}

test "ctl edit: planUndo restores and allows closing created surfaces only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Current: the undone apply moved 4 next to 1 and spawned 0xa and 0xb;
    // 3 has since exited.
    var current = try json.parseFromSliceLeaky(Value, alloc,
        \\{"version":1,"windows":[
        \\ {"id":1,"quick_terminal":false,"tabs":[{"tree":
        \\  {"type":"split","layout":"horizontal","ratio":0.5,
        \\   "left":{"type":"split","layout":"vertical","ratio":0.5,
        \\     "left":{"type":"surface","id":"0x1"},"right":{"type":"surface","id":"0x4"}},
        \\   "right":{"type":"surface","id":"0x2"}}},
        \\  {"tree":{"type":"surface","id":"0xa"}}]},
        \\ {"id":2,"quick_terminal":false,"tabs":[{"zoomed":null,"tree":{"type":"surface","id":"0x5"}}]},
        \\ {"id":7,"quick_terminal":false,"tabs":[{"tree":{"type":"surface","id":"0xb"}}]},
        \\ {"id":9,"quick_terminal":true,"tabs":[{"tree":{"type":"surface","id":"0x9"}}]}]}
    , .{});
    var saved = try json.parseFromSliceLeaky(Value, alloc, fixture, .{});
    const plan = try planUndo(alloc, &current, &saved, &.{ 0xa, 0xb, 0xc });
    try expectDoc(alloc, plan.spec, "W1/1[(h0.25 1 2)|4] W2/0[5*5] focus=2");
    try testing.expectEqualSlices(u64, &.{ 0xa, 0xb }, plan.unplaced);
    try testing.expectEqual(@as(usize, 0), plan.refused.len);
    try testing.expect(plan.allowClose());
}

test "ctl edit: planUndo refuses closing pre-existing surfaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Surface 6 was opened after the saved snapshot (not by the undone
    // apply); window 2 is gone so its saved tab becomes a new window.
    var current = try json.parseFromSliceLeaky(Value, alloc,
        \\{"version":1,"focused_surface":"0x6","windows":[
        \\ {"id":1,"tabs":[{"tree":{"type":"split","layout":"horizontal","ratio":0.5,
        \\   "left":{"type":"surface","id":"0x1"},"right":{"type":"surface","id":"0x5"}}},
        \\  {"tree":{"type":"surface","id":"0x6"}}]}]}
    , .{});
    var saved = try json.parseFromSliceLeaky(Value, alloc, fixture, .{});
    const plan = try planUndo(alloc, &current, &saved, &.{});
    try expectDoc(alloc, plan.spec, "W1/0[1] Wnew/0[5*5]");
    try testing.expectEqualSlices(u64, &.{6}, plan.unplaced);
    try testing.expectEqualSlices(u64, &.{6}, plan.refused);
}

test "ctl edit: planUndo with nothing left" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var current = try json.parseFromSliceLeaky(Value, alloc,
        \\{"version":1,"windows":[{"id":4,"tabs":[{"tree":{"type":"surface","id":"0x77"}}]}]}
    , .{});
    var saved = try json.parseFromSliceLeaky(Value, alloc, fixture, .{});
    try testing.expectError(error.NothingToRestore, planUndo(alloc, &current, &saved, &.{}));
}

test "ctl edit: createdIds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const result = try json.parseFromSliceLeaky(Value, alloc,
        \\{"created":{"a":"0x00000000000000aa","b":null},"closed":[],"dry_run":false}
    , .{});
    try testing.expectEqualSlices(u64, &.{0xaa}, try createdIds(alloc, result));
}
