//! Validation and planning for ApplyLayout. Pure: works on a plain snapshot
//! of the live windows (`Current`) so every rule is unit-testable. apply.zig
//! gathers the snapshot, calls `plan`, and executes the result.

const std = @import("std");
const Allocator = std.mem.Allocator;
const spec = @import("spec.zig");

pub const Error = error{ InvalidLayout, OutOfMemory, WriteFailed };

/// Snapshot of the live application.
pub const Current = struct {
    windows: []const Window,

    pub const Window = struct {
        id: c_uint,
        quick_terminal: bool = false,
        /// Index of the selected tab, if any.
        selected_tab: ?usize = null,
        tabs: []const Tab,
    };

    pub const Tab = struct {
        /// Surface ids in tree order. Null for a surface that has no id yet
        /// (it is created but its core surface is not initialized).
        surfaces: []const ?u64,
    };
};

/// A tab of the current snapshot.
pub const Loc = struct {
    window: usize,
    tab: usize,

    fn order(self: Loc) usize {
        // Windows never have anywhere near 2^16 tabs; this only orders
        // candidates deterministically.
        return (self.window << 16) | self.tab;
    }
};

pub const Plan = struct {
    /// Parallel to `spec.windows`.
    windows: []const Window,

    /// Current tabs that no spec tab adopts. They are closed after the
    /// surfaces that stay were moved out of them.
    closed_tabs: []const Loc,

    /// Current surfaces the spec does not place (only possible with
    /// `allow_close`). They are closed.
    unplaced: []const Unplaced,

    pub const Window = struct {
        /// Index into `Current.windows`; null for a new window.
        current: ?usize,
        /// Index of the tab to select (within the spec window).
        selected_tab: usize,
        /// Parallel to the spec window's tabs.
        tabs: []const Tab,
    };

    pub const Tab = struct {
        /// The current tab reused (moved/rebuilt in place) for this spec
        /// tab, keeping its tab-level state such as a title override.
        /// Null creates a new tab.
        reuse: ?Loc,
    };

    pub const Unplaced = struct {
        loc: Loc,
        id: ?u64,
    };
};

/// Where a current surface lives.
const Where = struct { loc: Loc, quick: bool };

/// Spec coordinates (`windows[window].tabs[tab]`) of a placed surface.
const SpecLoc = struct { window: usize, tab: usize };

/// Validate `s` against `cur` and decide which current tabs are reused.
/// On error.InvalidLayout a precise reason is written to `diag`.
pub fn plan(
    arena: Allocator,
    s: spec.Spec,
    cur: Current,
    opts: spec.Options,
    diag: *std.Io.Writer,
) Error!Plan {
    if (s.windows.len == 0) {
        try diag.writeAll("layout has no windows");
        return error.InvalidLayout;
    }

    // Where every current surface lives.
    var existing: std.AutoHashMapUnmanaged(u64, Where) = .empty;
    for (cur.windows, 0..) |w, wi| for (w.tabs, 0..) |t, ti| for (t.surfaces) |id_| {
        const id = id_ orelse continue;
        try existing.put(arena, id, .{
            .loc = .{ .window = wi, .tab = ti },
            .quick = w.quick_terminal,
        });
    };

    // Spec tab coordinates of every placed existing surface / new name.
    var placed: std.AutoHashMapUnmanaged(u64, SpecLoc) = .empty;
    var names: std.StringHashMapUnmanaged(SpecLoc) = .empty;

    // Current window index per spec window.
    const plan_windows = try arena.alloc(Plan.Window, s.windows.len);
    for (s.windows, 0..) |w, wi| {
        const current: ?usize = if (w.id) |id| current: {
            const idx = for (cur.windows, 0..) |cw, i| {
                if (cw.id == id) break i;
            } else {
                try diag.print("windows[{d}]: unknown window id {d}", .{ wi, id });
                return error.InvalidLayout;
            };
            if (cur.windows[idx].quick_terminal) {
                try diag.print("windows[{d}]: window id {d} is the quick terminal, which cannot be changed", .{ wi, id });
                return error.InvalidLayout;
            }
            for (s.windows[0..wi], 0..) |prev, pi| if (prev.id == id) {
                try diag.print("windows[{d}]: window id {d} is listed twice (also windows[{d}])", .{ wi, id, pi });
                return error.InvalidLayout;
            };
            break :current idx;
        } else null;

        if (w.tabs.len == 0) {
            try diag.print("windows[{d}]: a window needs at least one tab", .{wi});
            return error.InvalidLayout;
        }
        if (w.selected_tab) |sel| if (sel >= w.tabs.len) {
            try diag.print("windows[{d}]: selected_tab {d} is out of range ({d} tabs)", .{ wi, sel, w.tabs.len });
            return error.InvalidLayout;
        };

        for (w.tabs, 0..) |t, ti| {
            var walker: Walker = .{
                .arena = arena,
                .diag = diag,
                .wi = wi,
                .ti = ti,
                .existing = &existing,
                .placed = &placed,
                .names = &names,
            };
            try walker.walk(t.root);
        }

        plan_windows[wi] = .{
            .current = current,
            .selected_tab = 0,
            .tabs = &.{},
        };
    }

    // Zoomed refs must name a leaf of their own tab.
    for (s.windows, 0..) |w, wi| for (w.tabs, 0..) |t, ti| {
        const ref = t.zoomed orelse continue;
        const at: ?SpecLoc = switch (ref) {
            .id => |id| placed.get(id),
            .name => |n| names.get(n),
        };
        if (at == null or at.?.window != wi or at.?.tab != ti) {
            try diag.print("windows[{d}].tabs[{d}]: zoomed surface ", .{ wi, ti });
            try writeRef(diag, ref);
            try diag.writeAll(" is not a surface of this tab");
            return error.InvalidLayout;
        }
    };

    if (s.focus) |ref| {
        const found = switch (ref) {
            .id => |id| placed.contains(id),
            .name => |n| names.contains(n),
        };
        if (!found) {
            try diag.writeAll("focus: surface ");
            try writeRef(diag, ref);
            try diag.writeAll(" is not placed by the layout");
            return error.InvalidLayout;
        }
    }

    // Every current (non-quick-terminal) surface must be placed unless
    // the caller allows closing.
    var unplaced: std.ArrayList(Plan.Unplaced) = .empty;
    for (cur.windows, 0..) |w, wi| {
        if (w.quick_terminal) continue;
        for (w.tabs, 0..) |t, ti| for (t.surfaces) |id_| {
            if (id_) |id| if (placed.contains(id)) continue;
            try unplaced.append(arena, .{ .loc = .{ .window = wi, .tab = ti }, .id = id_ });
        };
    }
    if (unplaced.items.len > 0 and !opts.allow_close) {
        try diag.writeAll("surfaces not placed by the layout (place them or pass allow_close to close them):");
        for (unplaced.items) |u| {
            if (u.id) |id| {
                try diag.print(" 0x{x:0>16}", .{id});
            } else {
                try diag.writeAll(" <surface still starting, no id yet>");
            }
            try diag.print(" (window {d} tab {d})", .{ cur.windows[u.loc.window].id, u.loc.tab });
        }
        return error.InvalidLayout;
    }

    // Decide which current tab each spec tab adopts: the unused current
    // tab holding most of its existing surfaces, preferring a tab that is
    // already in the target window, then the earliest one.
    var reused: std.AutoHashMapUnmanaged(Loc, void) = .empty;
    for (s.windows, plan_windows) |w, *pw| {
        const tabs = try arena.alloc(Plan.Tab, w.tabs.len);
        for (w.tabs, tabs) |t, *pt| {
            var counts: std.AutoArrayHashMapUnmanaged(Loc, usize) = .empty;
            try countExisting(arena, t.root, &existing, &counts);

            var best: ?Loc = null;
            var best_count: usize = 0;
            for (counts.keys(), counts.values()) |loc, count| {
                if (reused.contains(loc)) continue;
                const better = if (best) |b| better: {
                    if (count != best_count) break :better count > best_count;
                    const loc_home = pw.current != null and loc.window == pw.current.?;
                    const best_home = pw.current != null and b.window == pw.current.?;
                    if (loc_home != best_home) break :better loc_home;
                    break :better loc.order() < b.order();
                } else true;
                if (better) {
                    best = loc;
                    best_count = count;
                }
            }
            if (best) |b| try reused.put(arena, b, {});
            pt.* = .{ .reuse = best };
        }
        pw.tabs = tabs;

        pw.selected_tab = selected: {
            if (w.selected_tab) |sel| break :selected sel;
            const ci = pw.current orelse break :selected 0;
            const cur_sel = cur.windows[ci].selected_tab orelse break :selected 0;
            for (tabs, 0..) |pt, i| if (pt.reuse) |r| {
                if (r.window == ci and r.tab == cur_sel) break :selected i;
            };
            break :selected 0;
        };
    }

    var closed_tabs: std.ArrayList(Loc) = .empty;
    for (cur.windows, 0..) |w, wi| {
        if (w.quick_terminal) continue;
        for (0..w.tabs.len) |ti| {
            const loc: Loc = .{ .window = wi, .tab = ti };
            if (!reused.contains(loc)) try closed_tabs.append(arena, loc);
        }
    }

    return .{
        .windows = plan_windows,
        .closed_tabs = closed_tabs.items,
        .unplaced = unplaced.items,
    };
}

/// Visits one spec tab's tree, checking leaves and splits.
const Walker = struct {
    arena: Allocator,
    diag: *std.Io.Writer,
    wi: usize,
    ti: usize,
    existing: *const std.AutoHashMapUnmanaged(u64, Where),
    placed: *std.AutoHashMapUnmanaged(u64, SpecLoc),
    names: *std.StringHashMapUnmanaged(SpecLoc),
    nodes: usize = 0,

    /// Split trees address nodes with 16-bit handles.
    const max_nodes = std.math.maxInt(u16) - 1;

    fn fail(self: *Walker, comptime fmt: []const u8, args: anytype) Error {
        try self.diag.print("windows[{d}].tabs[{d}]: ", .{ self.wi, self.ti });
        try self.diag.print(fmt, args);
        return error.InvalidLayout;
    }

    fn walk(self: *Walker, node: *const spec.Node) Error!void {
        self.nodes += 1;
        if (self.nodes > max_nodes) return self.fail("too many splits", .{});

        switch (node.*) {
            .split => |s| {
                const r: f32 = @floatCast(s.ratio);
                if (std.math.isNan(r) or r <= 0 or r >= 1) {
                    return self.fail("split ratio {d} is not between 0 and 1", .{r});
                }
                try self.walk(s.left);
                try self.walk(s.right);
            },
            .surface => |leaf| switch (leaf) {
                .existing => |id| {
                    const where = self.existing.get(id) orelse
                        return self.fail("unknown surface 0x{x:0>16}", .{id});
                    if (where.quick) {
                        return self.fail("surface 0x{x:0>16} belongs to the quick terminal, which cannot be changed", .{id});
                    }
                    const gop = try self.placed.getOrPut(self.arena, id);
                    if (gop.found_existing) {
                        return self.fail("surface 0x{x:0>16} is placed twice (also windows[{d}].tabs[{d}])", .{ id, gop.value_ptr.window, gop.value_ptr.tab });
                    }
                    gop.value_ptr.* = .{ .window = self.wi, .tab = self.ti };
                },
                .new => |n| {
                    if (n.name.len == 0) return self.fail("a new surface needs a non-empty name", .{});
                    const gop = try self.names.getOrPut(self.arena, n.name);
                    if (gop.found_existing) {
                        return self.fail("new surface name \"{s}\" is used twice (also windows[{d}].tabs[{d}])", .{ n.name, gop.value_ptr.window, gop.value_ptr.tab });
                    }
                    gop.value_ptr.* = .{ .window = self.wi, .tab = self.ti };
                    if (n.command) |c| switch (c) {
                        .argv => |argv| if (argv.len == 0 or argv[0].len == 0) {
                            return self.fail("new surface \"{s}\" has an empty command", .{n.name});
                        },
                        .shell => |sh| if (sh.len == 0) {
                            return self.fail("new surface \"{s}\" has an empty command", .{n.name});
                        },
                    };
                },
            },
        }
    }
};

fn countExisting(
    arena: Allocator,
    node: *const spec.Node,
    existing: anytype,
    counts: *std.AutoArrayHashMapUnmanaged(Loc, usize),
) Allocator.Error!void {
    switch (node.*) {
        .split => |s| {
            try countExisting(arena, s.left, existing, counts);
            try countExisting(arena, s.right, existing, counts);
        },
        .surface => |leaf| switch (leaf) {
            .existing => |id| {
                const where = existing.get(id).?;
                const gop = try counts.getOrPut(arena, where.loc);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            },
            .new => {},
        },
    }
}

pub fn writeRef(w: *std.Io.Writer, ref: spec.Ref) std.Io.Writer.Error!void {
    switch (ref) {
        .id => |id| try w.print("0x{x:0>16}", .{id}),
        .name => |n| try w.print("\"{s}\"", .{n}),
    }
}

// ---------------------------------------------------------------------
// Tests

const testing = std.testing;

fn leafId(id: u64) spec.Node {
    return .{ .surface = .{ .existing = id } };
}

fn leafNew(name: []const u8) spec.Node {
    return .{ .surface = .{ .new = .{ .name = name } } };
}

fn hsplit(l: *const spec.Node, r: *const spec.Node) spec.Node {
    return .{ .split = .{ .layout = .horizontal, .left = l, .right = r } };
}

/// Two windows: window 1 has tabs [A|B] and [C], window 2 has [D].
/// Window 9 is the quick terminal with [Q].
const cur_basic: Current = .{ .windows = &.{
    .{ .id = 1, .selected_tab = 1, .tabs = &.{
        .{ .surfaces = &.{ 0xA, 0xB } },
        .{ .surfaces = &.{0xC} },
    } },
    .{ .id = 2, .selected_tab = 0, .tabs = &.{
        .{ .surfaces = &.{0xD} },
    } },
    .{ .id = 9, .quick_terminal = true, .tabs = &.{
        .{ .surfaces = &.{0xF} },
    } },
} };

const TestResult = struct {
    arena: std.heap.ArenaAllocator,
    diag: std.Io.Writer.Allocating,
    result: Error!Plan,

    fn deinit(self: *TestResult) void {
        self.diag.deinit();
        self.arena.deinit();
    }
};

fn run(s: spec.Spec, opts: spec.Options) TestResult {
    var r: TestResult = .{
        .arena = .init(testing.allocator),
        .diag = .init(testing.allocator),
        .result = undefined,
    };
    r.result = plan(r.arena.allocator(), s, cur_basic, opts, &r.diag.writer);
    return r;
}

fn expectInvalid(s: spec.Spec, opts: spec.Options, expected: []const u8) !void {
    var r = run(s, opts);
    defer r.deinit();
    try testing.expectError(error.InvalidLayout, r.result);
    try testing.expectEqualStrings(expected, r.diag.written());
}

test "plan: identity layout reuses every tab" {
    const a = leafId(0xA);
    const b = leafId(0xB);
    const ab = hsplit(&a, &b);
    const c = leafId(0xC);
    const d = leafId(0xD);
    var r = run(.{ .windows = &.{
        .{ .id = 1, .tabs = &.{ .{ .root = &ab }, .{ .root = &c } } },
        .{ .id = 2, .tabs = &.{.{ .root = &d }} },
    } }, .{});
    defer r.deinit();
    const p = try r.result;
    try testing.expectEqual(@as(usize, 2), p.windows.len);
    try testing.expectEqual(@as(?usize, 0), p.windows[0].current);
    try testing.expectEqual(@as(?Loc, .{ .window = 0, .tab = 0 }), p.windows[0].tabs[0].reuse);
    try testing.expectEqual(@as(?Loc, .{ .window = 0, .tab = 1 }), p.windows[0].tabs[1].reuse);
    try testing.expectEqual(@as(?Loc, .{ .window = 1, .tab = 0 }), p.windows[1].tabs[0].reuse);
    // Current selection is kept when the spec does not set one.
    try testing.expectEqual(@as(usize, 1), p.windows[0].selected_tab);
    try testing.expectEqual(@as(usize, 0), p.closed_tabs.len);
    try testing.expectEqual(@as(usize, 0), p.unplaced.len);
}

test "plan: moving surfaces and emptying a window" {
    // D moves next to C, B moves to a new window with a new surface.
    // Window 2 is left out and empties.
    const a = leafId(0xA);
    const c = leafId(0xC);
    const d = leafId(0xD);
    const cd = hsplit(&c, &d);
    const b = leafId(0xB);
    const n = leafNew("n");
    const bn = hsplit(&b, &n);
    var r = run(.{ .windows = &.{
        .{ .id = 1, .selected_tab = 0, .tabs = &.{ .{ .root = &cd }, .{ .root = &a } } },
        .{ .tabs = &.{.{ .root = &bn }} },
    } }, .{});
    defer r.deinit();
    const p = try r.result;
    // [C|D] keeps C's tab (preferring the home window over window 2's tab).
    try testing.expectEqual(@as(?Loc, .{ .window = 0, .tab = 1 }), p.windows[0].tabs[0].reuse);
    try testing.expectEqual(@as(?Loc, .{ .window = 0, .tab = 0 }), p.windows[0].tabs[1].reuse);
    try testing.expectEqual(@as(?usize, null), p.windows[1].current);
    // [B|n]: A's old tab was taken, so this is a new tab.
    try testing.expectEqual(@as(?Loc, null), p.windows[1].tabs[0].reuse);
    try testing.expectEqual(@as(usize, 1), p.closed_tabs.len);
    try testing.expectEqual(Loc{ .window = 1, .tab = 0 }, p.closed_tabs[0]);
}

test "plan: unplaced surfaces" {
    const a = leafId(0xA);
    const b = leafId(0xB);
    const ab = hsplit(&a, &b);
    const s: spec.Spec = .{ .windows = &.{
        .{ .id = 1, .tabs = &.{.{ .root = &ab }} },
    } };
    try expectInvalid(s, .{},
        \\surfaces not placed by the layout (place them or pass allow_close to close them): 0x000000000000000c (window 1 tab 1) 0x000000000000000d (window 2 tab 0)
    );

    var r = run(s, .{ .allow_close = true });
    defer r.deinit();
    const p = try r.result;
    try testing.expectEqual(@as(usize, 2), p.unplaced.len);
    try testing.expectEqual(@as(?u64, 0xC), p.unplaced[0].id);
    try testing.expectEqual(@as(?u64, 0xD), p.unplaced[1].id);
    // Quick terminal tabs are never closed.
    try testing.expectEqual(@as(usize, 2), p.closed_tabs.len);
}

test "plan: validation errors" {
    const a = leafId(0xA);
    const a2 = leafId(0xA);
    const aa = hsplit(&a, &a2);
    const q = leafId(0xF);
    const x = leafId(0x99);
    const n1 = leafNew("n");
    const n2 = leafNew("n");
    const nn = hsplit(&n1, &n2);
    const empty_name = leafNew("");
    const bad_cmd: spec.Node = .{ .surface = .{ .new = .{ .name = "c", .command = .{ .argv = &.{} } } } };
    const bad_ratio: spec.Node = .{ .split = .{ .layout = .vertical, .ratio = 1, .left = &n1, .right = &a } };
    const opts: spec.Options = .{ .allow_close = true };

    try expectInvalid(.{ .windows = &.{} }, opts, "layout has no windows");
    try expectInvalid(.{ .windows = &.{.{ .id = 5, .tabs = &.{.{ .root = &a }} }} }, opts, "windows[0]: unknown window id 5");
    try expectInvalid(
        .{ .windows = &.{.{ .id = 9, .tabs = &.{.{ .root = &a }} }} },
        opts,
        "windows[0]: window id 9 is the quick terminal, which cannot be changed",
    );
    try expectInvalid(
        .{ .windows = &.{ .{ .id = 1, .tabs = &.{.{ .root = &a }} }, .{ .id = 1, .tabs = &.{.{ .root = &n1 }} } } },
        opts,
        "windows[1]: window id 1 is listed twice (also windows[0])",
    );
    try expectInvalid(.{ .windows = &.{.{ .tabs = &.{} }} }, opts, "windows[0]: a window needs at least one tab");
    try expectInvalid(
        .{ .windows = &.{.{ .selected_tab = 1, .tabs = &.{.{ .root = &a }} }} },
        opts,
        "windows[0]: selected_tab 1 is out of range (1 tabs)",
    );
    try expectInvalid(.{ .windows = &.{.{ .tabs = &.{.{ .root = &x }} }} }, opts, "windows[0].tabs[0]: unknown surface 0x0000000000000099");
    try expectInvalid(
        .{ .windows = &.{.{ .tabs = &.{.{ .root = &q }} }} },
        opts,
        "windows[0].tabs[0]: surface 0x000000000000000f belongs to the quick terminal, which cannot be changed",
    );
    try expectInvalid(
        .{ .windows = &.{.{ .tabs = &.{.{ .root = &aa }} }} },
        opts,
        "windows[0].tabs[0]: surface 0x000000000000000a is placed twice (also windows[0].tabs[0])",
    );
    try expectInvalid(
        .{ .windows = &.{.{ .tabs = &.{ .{ .root = &a }, .{ .root = &nn } } }} },
        opts,
        "windows[0].tabs[1]: new surface name \"n\" is used twice (also windows[0].tabs[1])",
    );
    try expectInvalid(.{ .windows = &.{.{ .tabs = &.{.{ .root = &empty_name }} }} }, opts, "windows[0].tabs[0]: a new surface needs a non-empty name");
    try expectInvalid(.{ .windows = &.{.{ .tabs = &.{.{ .root = &bad_cmd }} }} }, opts, "windows[0].tabs[0]: new surface \"c\" has an empty command");
    try expectInvalid(.{ .windows = &.{.{ .tabs = &.{.{ .root = &bad_ratio }} }} }, opts, "windows[0].tabs[0]: split ratio 1 is not between 0 and 1");
    try expectInvalid(
        .{ .windows = &.{.{ .tabs = &.{ .{ .root = &a }, .{ .root = &n1, .zoomed = .{ .id = 0xA } } } }} },
        opts,
        "windows[0].tabs[1]: zoomed surface 0x000000000000000a is not a surface of this tab",
    );
    try expectInvalid(
        .{ .windows = &.{.{ .tabs = &.{.{ .root = &a }} }}, .focus = .{ .name = "zz" } },
        opts,
        "focus: surface \"zz\" is not placed by the layout",
    );
}

test "plan: zoom and focus refs resolve" {
    const a = leafId(0xA);
    const n = leafNew("n");
    const an = hsplit(&a, &n);
    var r = run(.{
        .windows = &.{.{ .tabs = &.{.{ .root = &an, .zoomed = .{ .name = "n" } }} }},
        .focus = .{ .id = 0xA },
    }, .{ .allow_close = true });
    defer r.deinit();
    const p = try r.result;
    try testing.expectEqual(@as(?Loc, .{ .window = 0, .tab = 0 }), p.windows[0].tabs[0].reuse);
    try testing.expectEqual(@as(usize, 3), p.unplaced.len);
}

test "plan: surfaces without an id count as unplaced" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: std.Io.Writer.Allocating = .init(testing.allocator);
    defer diag.deinit();
    const cur: Current = .{ .windows = &.{
        .{ .id = 1, .tabs = &.{.{ .surfaces = &.{ 0xA, null } }} },
    } };
    const a = leafId(0xA);
    const s: spec.Spec = .{ .windows = &.{.{ .id = 1, .tabs = &.{.{ .root = &a }} }} };
    try testing.expectError(error.InvalidLayout, plan(arena.allocator(), s, cur, .{}, &diag.writer));
    try testing.expectEqualStrings(
        "surfaces not placed by the layout (place them or pass allow_close to close them): <surface still starting, no id yet> (window 1 tab 0)",
        diag.written(),
    );
}
