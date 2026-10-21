//! Applies a desired-layout spec to the live GTK application.
//!
//! Validation and tab matching live in plan.zig (pure, unit tested). This
//! file snapshots the live windows for it and then executes the plan:
//!
//!   1. Build every tab's new `Surface.Tree` up front (creating the spec's
//!      `new` surfaces), so running out of memory changes nothing visible.
//!   2. Hold all live windows open, move reused tabs into their target
//!      windows (`AdwTabView.transferPage`, which keeps the tab object),
//!      give each tab its new tree, insert tabs adopting a tree for the
//!      rest, and reorder pages to the spec order.
//!   3. Empty the tabs no spec tab adopted, which closes them. Surfaces
//!      nobody placed (allow_close) lose their last reference and close
//!      without confirmation.
//!   4. Reconnect window signal handlers, fix each tab's focus target,
//!      select tabs, release the windows (emptied ones close), present new
//!      windows and apply `focus`.
//!
//! Surfaces are only ever re-parented: their widgets (and the
//! SurfaceScrolledWindow around them) are reused by SplitTree.buildTree, so
//! the PTY and the running program are untouched.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;
const plan = @import("plan.zig");
const spec = @import("spec.zig");

pub const Error = error{ InvalidLayout, OutOfMemory, WriteFailed };

pub const Created = struct {
    /// The `new` leaf's name from the spec.
    name: []const u8,
    /// Newly created GTK surface. Its core surface (and id) appears only after
    /// the widget is first realized/resized; the caller waits for that.
    surface: *Surface,
};

pub const Result = struct {
    created: []const Created,
    /// Ids of existing surfaces closed because opts.allow_close was set.
    /// With opts.dry_run: the ids that would be closed.
    closed: []const u64,
};

/// Validate `s` against the live application, then (unless opts.dry_run)
/// rearrange every window/tab/split to match it. Running surfaces are moved,
/// never restarted. On error.InvalidLayout nothing was changed and a
/// human-readable reason was written to `diag`.
///
/// The created surfaces are owned by their trees; they stay valid while
/// they are placed (the caller should ref them if it keeps them across
/// main loop iterations).
pub fn apply(
    app: *Application,
    arena: Allocator,
    s: spec.Spec,
    opts: spec.Options,
    diag: *std.Io.Writer,
) Error!Result {
    const live = try Live.gather(app, arena);
    const p = try plan.plan(arena, s, live.current, opts, diag);

    var closed: std.ArrayList(u64) = .empty;
    for (p.unplaced) |u| if (u.id) |id| try closed.append(arena, id);
    if (opts.dry_run) return .{ .created = &.{}, .closed = closed.items };

    const created = try execute(app, arena, s, p, &live);
    return .{ .created = created, .closed = closed.items };
}

/// The live windows, in the shape plan.zig expects plus the GTK objects.
const Live = struct {
    windows: []const LiveWindow,
    current: plan.Current,
    by_id: std.AutoHashMapUnmanaged(u64, *Surface),
    /// The active surface of the most recently focused window.
    focused: ?*Surface,

    const LiveWindow = struct {
        win: *Window,
        tabs: []const *Tab,
    };

    fn gather(app: *Application, arena: Allocator) Allocator.Error!Live {
        var wins: std.ArrayList(*Window) = .empty;
        var list: ?*glib.List = @as(?*glib.List, app.as(gtk.Application).getWindows());
        while (list) |node| : (list = node.f_next) {
            const ptr = node.f_data orelse continue;
            const gwin: *gtk.Window = @ptrCast(@alignCast(ptr));
            const win = gobject.ext.cast(Window, gwin) orelse continue;
            try wins.append(arena, win);
        }

        // GTK lists windows most recently focused first.
        const focused: ?*Surface = for (wins.items) |win| {
            if (!win.isQuickTerminal()) break win.getActiveSurface();
        } else null;

        // Stable order for plan's tie-breaking.
        std.mem.sort(*Window, wins.items, {}, struct {
            fn lessThan(_: void, a: *Window, b: *Window) bool {
                return a.as(gtk.ApplicationWindow).getId() < b.as(gtk.ApplicationWindow).getId();
            }
        }.lessThan);

        var by_id: std.AutoHashMapUnmanaged(u64, *Surface) = .empty;
        const windows = try arena.alloc(LiveWindow, wins.items.len);
        const cur_windows = try arena.alloc(plan.Current.Window, wins.items.len);
        for (wins.items, windows, cur_windows) |win, *lw, *cw| {
            const tab_view = win.getTabView();
            var tabs: std.ArrayList(*Tab) = .empty;
            var cur_tabs: std.ArrayList(plan.Current.Tab) = .empty;
            var selected: ?usize = null;
            const selected_page = tab_view.getSelectedPage();
            const n: usize = @intCast(tab_view.getNPages());
            for (0..n) |i| {
                const page = tab_view.getNthPage(@intCast(i));
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
                if (selected_page == page) selected = tabs.items.len;

                var ids: std.ArrayList(?u64) = .empty;
                if (tab.getSurfaceTree()) |tree| {
                    var it = tree.iterator();
                    while (it.next()) |entry| {
                        const core = entry.view.core() orelse {
                            try ids.append(arena, null);
                            continue;
                        };
                        try ids.append(arena, core.id);
                        try by_id.put(arena, core.id, entry.view);
                    }
                }
                try tabs.append(arena, tab);
                try cur_tabs.append(arena, .{ .surfaces = ids.items });
            }
            lw.* = .{ .win = win, .tabs = tabs.items };
            cw.* = .{
                .id = win.as(gtk.ApplicationWindow).getId(),
                .quick_terminal = win.isQuickTerminal(),
                .selected_tab = selected,
                .tabs = cur_tabs.items,
            };
        }

        return .{
            .windows = windows,
            .current = .{ .windows = cur_windows },
            .by_id = by_id,
            .focused = focused,
        };
    }
};

/// A spec tab's tree, built before anything is mutated.
const BuiltTab = struct {
    tree: Surface.Tree,
    /// The leaf that should hold the tab's focus if the current one left.
    focus_default: *Surface,
};

fn execute(
    app: *Application,
    arena: Allocator,
    s: spec.Spec,
    p: plan.Plan,
    live: *const Live,
) Allocator.Error![]const Created {
    const alloc = app.allocator();

    // Keep every live surface alive until we are done. Surfaces that end
    // up in no tree are finalized (closed) when these are released.
    var held: std.ArrayList(*Surface) = .empty;
    defer for (held.items) |v| v.unref();
    {
        var it = live.by_id.valueIterator();
        while (it.next()) |v| {
            try held.ensureUnusedCapacity(arena, 1);
            held.appendAssumeCapacity(v.*.ref());
        }
    }
    if (live.focused) |v| {
        try held.ensureUnusedCapacity(arena, 1);
        held.appendAssumeCapacity(v.ref());
    }

    // Phase 1: create new surfaces and build all trees.
    var created: std.ArrayList(Created) = .empty;
    var by_name: std.StringHashMapUnmanaged(*Surface) = .empty;
    // Our creation references; trees own the surfaces after this.
    defer for (created.items) |c| c.surface.unref();

    const built = try arena.alloc([]BuiltTab, s.windows.len);
    var built_count: usize = 0;
    defer for (built[0..built_count]) |tabs| for (tabs) |*t| t.tree.deinit();
    for (s.windows, built) |w, *tabs_out| {
        const window_parent = firstExisting(live, w.tabs);
        const tabs = try arena.alloc(BuiltTab, w.tabs.len);
        var n: usize = 0;
        errdefer for (tabs[0..n]) |*t| t.tree.deinit();
        for (w.tabs, tabs) |t, *out| {
            var builder: Builder = .{
                .arena = arena,
                .live = live,
                .created = &created,
                .by_name = &by_name,
                .zoomed_ref = t.zoomed,
                .parent = if (firstExisting(live, &.{t})) |v|
                    .{ .surface = v, .context = .split }
                else if (window_parent) |v|
                    .{ .surface = v, .context = .tab }
                else if (live.focused) |v|
                    .{ .surface = v, .context = .window }
                else
                    null,
            };
            _ = try builder.build(t.root);
            out.* = .{
                .tree = Surface.Tree.fromNodes(alloc, builder.nodes.items, builder.zoomed) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // plan.zig validated ratios and the builder emits pre-order.
                    error.InvalidNodes => unreachable,
                },
                .focus_default = builder.focus_default.?,
            };
            n += 1;
        }
        tabs_out.* = tabs;
        built_count += 1;
    }

    const targets = try arena.alloc(*Window, s.windows.len);
    const tabs = try arena.alloc([]*Tab, s.windows.len);
    for (tabs, s.windows) |*t, w| t.* = try arena.alloc(*Tab, w.tabs.len);

    // Phase 2: mutate. Nothing below can fail (tree clones panic on OOM
    // like everywhere else in the GTK apprt).
    for (live.windows) |lw| lw.win.holdClose();
    defer for (live.windows) |lw| lw.win.releaseClose();

    for (p.windows, targets, 0..) |pw, *target, wi| {
        target.* = if (pw.current) |ci| live.windows[ci].win else newWindow(app, live, s.windows[wi], built[wi]);
    }

    for (p.windows, built, targets, tabs) |pw, bt, target, tabs_out| {
        const target_view = target.getTabView();
        for (pw.tabs, bt, tabs_out) |pt, *b, *tab_out| {
            if (pt.reuse) |loc| {
                const lw = live.windows[loc.window];
                const tab = lw.tabs[loc.tab];
                if (lw.win != target) {
                    const src_view = lw.win.getTabView();
                    src_view.transferPage(
                        src_view.getPage(tab.as(gtk.Widget)),
                        target_view,
                        target_view.getNPages(),
                    );
                }
                tab.getSplitTree().setTree(&b.tree);
                tab_out.* = tab;
            } else {
                const tab = Tab.newWithTree(target.getConfig(), &b.tree);
                _ = target.insertTab(tab, target_view.getNPages());
                tab_out.* = tab;
            }
        }

        for (tabs_out, 0..) |tab, i| {
            const page = target_view.getPage(tab.as(gtk.Widget));
            _ = target_view.reorderPage(page, @intCast(i));
        }
    }

    // Empty the tabs nobody adopted; an empty tree closes its tab.
    for (p.closed_tabs) |loc| {
        live.windows[loc.window].tabs[loc.tab].getSplitTree().setTree(null);
    }

    for (tabs, built) |window_tabs, bt| for (window_tabs, bt) |tab, b| {
        const split_tree = tab.getSplitTree();
        const tree = split_tree.getTree() orelse continue;
        var it = tree.iterator();
        while (it.next()) |entry| entry.view.bindIsSplit(split_tree);

        const keep = if (split_tree.getLastFocusedSurface()) |v| tree.locate(v) != null else false;
        if (!keep) split_tree.setLastFocused(b.focus_default);
    };

    for (targets, tabs, p.windows) |target, window_tabs, pw| {
        target.syncSurfaceHandlers();
        const view = target.getTabView();
        view.setSelectedPage(view.getPage(window_tabs[pw.selected_tab].as(gtk.Widget)));
    }

    // New windows are shown last so they don't flash half built.
    for (targets, p.windows) |target, pw| {
        if (pw.current == null) target.as(gtk.Window).present();
    }

    // Focus: the requested surface, else (when new windows may have
    // taken it) the previously focused one if it is still placed.
    const focus: ?*Surface = if (s.focus) |ref| switch (ref) {
        .id => |id| live.by_id.get(id).?,
        .name => |name| by_name.get(name).?,
    } else if (live.focused) |v| focus: {
        for (p.windows) |pw| if (pw.current == null) break :focus v;
        break :focus null;
    } else null;
    if (focus) |v| focusSurface(targets, tabs, v);

    // Surfaces normally start on their first allocation, which never comes
    // for a tab that isn't shown. Start new surfaces in hidden tabs now so
    // their commands run (and they get ids) right away.
    for (targets, tabs) |target, window_tabs| {
        const view = target.getTabView();
        const area = tabArea(target);
        for (window_tabs) |tab| {
            if (view.getSelectedPage() == view.getPage(tab.as(gtk.Widget))) continue;
            const tree = tab.getSurfaceTree() orelse continue;
            startHidden(tree, .root, area);
        }
    }

    return created.items;
}

/// Width and height in device pixels.
const Area = struct { f64, f64 };

/// The size of a window's tab content in device pixels, falling back to
/// the window's default size for a window that was never shown.
fn tabArea(win: *Window) Area {
    const scale: f64 = @floatFromInt(@max(1, win.as(gtk.Widget).getScaleFactor()));
    const view = win.getTabView().as(gtk.Widget);
    var width: c_int = view.getWidth();
    var height: c_int = view.getHeight();
    if (width <= 0 or height <= 0) win.as(gtk.Window).getDefaultSize(&width, &height);
    if (width <= 0 or height <= 0) {
        width = 800;
        height = 600;
    }
    return .{ @as(f64, @floatFromInt(width)) * scale, @as(f64, @floatFromInt(height)) * scale };
}

/// Start every not yet started surface under `at`, splitting `area`
/// by the split ratios to estimate each surface's size.
fn startHidden(tree: *const Surface.Tree, at: Surface.Tree.Node.Handle, area: Area) void {
    switch (tree.nodes[at.idx()]) {
        .leaf => |surface| surface.startHidden(.{
            .width = @intFromFloat(@max(1, area[0])),
            .height = @intFromFloat(@max(1, area[1])),
        }),
        .split => |sp| {
            const ratio: f64 = @floatCast(sp.ratio);
            const left: Area, const right: Area = switch (sp.layout) {
                .horizontal => .{ .{ area[0] * ratio, area[1] }, .{ area[0] * (1 - ratio), area[1] } },
                .vertical => .{ .{ area[0], area[1] * ratio }, .{ area[0], area[1] * (1 - ratio) } },
            };
            startHidden(tree, sp.left, left);
            startHidden(tree, sp.right, right);
        },
    }
}

/// Turns a spec tree into pre-order split tree nodes.
const Builder = struct {
    arena: Allocator,
    live: *const Live,
    created: *std.ArrayList(Created),
    by_name: *std.StringHashMapUnmanaged(*Surface),
    zoomed_ref: ?spec.Ref,
    parent: ?Parent,

    nodes: std.ArrayList(Surface.Tree.Node) = .empty,
    zoomed: ?Surface.Tree.Node.Handle = null,
    focus_default: ?*Surface = null,

    const Parent = struct {
        surface: *Surface,
        context: apprt.surface.NewSurfaceContext,
    };

    fn build(self: *Builder, node: *const spec.Node) Allocator.Error!Surface.Tree.Node.Handle {
        const handle: Surface.Tree.Node.Handle = @fromBackingInt(@intCast(self.nodes.items.len));
        try self.nodes.append(self.arena, undefined);
        switch (node.*) {
            .split => |sp| {
                const left = try self.build(sp.left);
                const right = try self.build(sp.right);
                self.nodes.items[handle.idx()] = .{ .split = .{
                    .layout = switch (sp.layout) {
                        .horizontal => .horizontal,
                        .vertical => .vertical,
                    },
                    .ratio = sp.ratio,
                    .left = left,
                    .right = right,
                } };
            },
            .surface => |leaf| {
                const surface, const is_zoomed = switch (leaf) {
                    .existing => |id| .{
                        self.live.by_id.get(id).?,
                        if (self.zoomed_ref) |r| r == .id and r.id == id else false,
                    },
                    .new => |n| .{
                        try self.newSurface(n),
                        if (self.zoomed_ref) |r| r == .name and std.mem.eql(u8, r.name, n.name) else false,
                    },
                };
                self.nodes.items[handle.idx()] = .{ .leaf = surface };
                if (is_zoomed) {
                    self.zoomed = handle;
                    self.focus_default = surface;
                }
                if (self.focus_default == null) self.focus_default = surface;
            },
        }
        return handle;
    }

    fn newSurface(self: *Builder, n: spec.New) Allocator.Error!*Surface {
        try self.created.ensureUnusedCapacity(self.arena, 1);
        try self.by_name.ensureUnusedCapacity(self.arena, 1);

        const surface: *Surface = .new(.{
            .command = if (n.command) |c| switch (c) {
                .argv => |argv| configpkg.Command{ .direct = argv },
                .shell => |sh| configpkg.Command{ .shell = sh },
            } else null,
            .shell_integration = null,
            .working_directory = n.cwd,
            .title = n.title,
        });
        _ = surface.refSink();

        // Inherit font size (and cwd, if configured and no cwd was given)
        // like a split, tab or window created from the nearest surface.
        if (self.parent) |parent| if (parent.surface.core()) |core| {
            surface.setParent(core, parent.context);
        };

        self.created.appendAssumeCapacity(.{ .name = n.name, .surface = surface });
        self.by_name.putAssumeCapacity(n.name, surface);
        return surface;
    }
};

/// The first existing surface placed in the given spec tabs.
fn firstExisting(live: *const Live, tabs: []const spec.Tab) ?*Surface {
    for (tabs) |t| if (firstExistingNode(live, t.root)) |v| return v;
    return null;
}

fn firstExistingNode(live: *const Live, node: *const spec.Node) ?*Surface {
    return switch (node.*) {
        .split => |sp| firstExistingNode(live, sp.left) orelse firstExistingNode(live, sp.right),
        .surface => |leaf| switch (leaf) {
            .existing => |id| live.by_id.get(id).?,
            .new => null,
        },
    };
}

/// Create (but don't show) a window for a spec window without an id.
fn newWindow(
    app: *Application,
    live: *const Live,
    w: spec.Window,
    built: []const BuiltTab,
) *Window {
    const win = Window.new(app, .none);

    // Like Application.initAndShowWindow: the window follows the app config.
    _ = app.as(gobject.Object).bindProperty(
        "config",
        win.as(gobject.Object),
        "config",
        .{},
    );

    // Size: an existing surface keeps the size of the window it came
    // from; otherwise estimate from the config like a regular new window.
    if (firstExisting(live, w.tabs)) |surface| {
        if (surface.as(gtk.Widget).getRoot()) |root| {
            const old = root.as(gtk.Widget);
            const width = old.getWidth();
            const height = old.getHeight();
            if (width > 0 and height > 0) win.as(gtk.Window).setDefaultSize(width, height);
        }
    } else {
        const surface = built[w.selected_tab orelse 0].focus_default;
        surface.estimateInitialSize();
        if (surface.getDefaultSize()) |size| {
            win.as(gtk.Window).setDefaultSize(@intCast(size.width), @intCast(size.height));
        }
    }

    return win;
}

/// Select the tab holding `surface`, focus it and present its window.
/// Does nothing if the surface is not placed (e.g. it was closed).
fn focusSurface(targets: []const *Window, tabs: []const []*Tab, surface: *Surface) void {
    for (targets, tabs) |win, window_tabs| for (window_tabs) |tab| {
        const split_tree = tab.getSplitTree();
        const tree = split_tree.getTree() orelse continue;
        if (tree.locate(surface) == null) continue;

        const view = win.getTabView();
        view.setSelectedPage(view.getPage(tab.as(gtk.Widget)));
        // The tree is rebuilt on idle; it grabs focus for last_focused.
        split_tree.setLastFocused(surface);
        surface.grabFocus();
        win.as(gtk.Window).present();
        return;
    };
}
