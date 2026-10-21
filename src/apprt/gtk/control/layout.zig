//! GetLayout JSON writer and ApplyLayout spec/options parser.
//!
//! GetLayout document (version 1):
//!
//!   {"version":1,"focused_surface":"0x…"|null,
//!    "windows":[{"id":3,"active":true,"quick_terminal":false,"title":"…","selected_tab":0,
//!      "tabs":[{"index":0,"selected":true,"title":"…","zoomed":"0x…"|null,"tree":NODE|null}]}]}
//!
//! Split nodes are as in spec.zig. Surface leaves carry extra details that the
//! spec parser ignores:
//!
//!   {"type":"surface","id":"0x…"|null,"pid":int|null,"fg_pid":int|null,
//!    "fg_comm":"…"|null,"fg_cmdline":["…"]|null,"title":"…"|null,"cwd":"…"|null,
//!    "focused":bool}
//!
//! A surface whose terminal is not initialized yet (it has never been shown)
//! has a null id and null process fields.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;
const Window = @import("../class/window.zig").Window;
const procinfo = @import("procinfo.zig");
const spec = @import("spec.zig");

pub const ParseError = error{ InvalidSpec, OutOfMemory, WriteFailed };

pub const WriteError = Stringify.Error || Allocator.Error;

/// Write the GetLayout JSON document for every window of `app`. Windows are
/// ordered by id. `alloc` is only used for temporary buffers.
pub fn write(app: *Application, alloc: Allocator, w: *std.Io.Writer) WriteError!void {
    var windows: std.ArrayList(*Window) = .empty;
    defer windows.deinit(alloc);
    var list_: ?*glib.List = @as(?*glib.List, app.as(gtk.Application).getWindows());
    while (list_) |node| : (list_ = node.f_next) {
        const data = node.f_data orelse continue;
        const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
        const window = gobject.ext.cast(Window, gtk_window) orelse continue;
        try windows.append(alloc, window);
    }
    std.mem.sort(*Window, windows.items, {}, struct {
        fn lessThan(_: void, a: *Window, b: *Window) bool {
            return windowId(a) < windowId(b);
        }
    }.lessThan);

    // Only the active window's active surface has keyboard focus. We can't
    // use Surface.getFocused alone: it defaults to true and stays true in
    // inactive windows.
    const focused: ?*Surface = for (windows.items) |window| {
        if (window.as(gtk.Window).isActive() != 0) break window.getActiveSurface();
    } else null;

    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("version");
    try s.write(spec.version);
    try s.objectField("focused_surface");
    try writeId(&s, if (focused) |f| surfaceId(f) else null);
    try s.objectField("windows");
    try s.beginArray();
    for (windows.items) |window| try writeWindow(&s, alloc, window, focused);
    try s.endArray();
    try s.endObject();
}

fn windowId(window: *Window) c_uint {
    return window.as(gtk.ApplicationWindow).getId();
}

fn surfaceId(surface: *Surface) ?u64 {
    const core = surface.core() orelse return null;
    return core.id;
}

fn writeWindow(
    s: *Stringify,
    alloc: Allocator,
    window: *Window,
    focused: ?*Surface,
) WriteError!void {
    const tab_view = window.getTabView();
    const n_pages: usize = @intCast(@max(tab_view.getNPages(), 0));
    const selected_page = tab_view.getSelectedPage();
    const selected_index: ?usize = if (selected_page) |page|
        @intCast(tab_view.getPagePosition(page))
    else
        null;

    try s.beginObject();
    try s.objectField("id");
    try s.write(windowId(window));
    try s.objectField("active");
    try s.write(window.as(gtk.Window).isActive() != 0);
    try s.objectField("quick_terminal");
    try s.write(window.isQuickTerminal());
    try s.objectField("title");
    try writeText(s, alloc, if (window.as(gtk.Window).getTitle()) |t| std.mem.span(t) else null);
    try s.objectField("selected_tab");
    try s.write(selected_index);
    try s.objectField("tabs");
    try s.beginArray();
    for (0..n_pages) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;

        try s.beginObject();
        try s.objectField("index");
        try s.write(i);
        try s.objectField("selected");
        try s.write(selected_index == i);
        try s.objectField("title");
        try writeText(s, alloc, std.mem.span(page.getTitle()));

        const tree_: ?*const Surface.Tree = tab.getSurfaceTree();
        try s.objectField("zoomed");
        try writeId(s, zoomed: {
            const tree = tree_ orelse break :zoomed null;
            const handle = tree.zoomed orelse break :zoomed null;
            break :zoomed switch (tree.nodes[handle.idx()]) {
                .leaf => |surface| surfaceId(surface),
                .split => null,
            };
        });
        try s.objectField("tree");
        if (tree_) |tree| {
            try writeTree(Surface.Tree, s, tree, SurfaceLeaf{
                .alloc = alloc,
                .focused = focused,
            });
        } else try s.write(null);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// Writes a GTK surface leaf with its process details.
const SurfaceLeaf = struct {
    alloc: Allocator,
    focused: ?*Surface,

    pub fn write(self: SurfaceLeaf, s: *Stringify, surface: *Surface) WriteError!void {
        const core_ = surface.core();
        const pid: ?u64 = if (core_) |core| core.getProcessInfo(.session_pid) else null;
        const fg_pid: ?u64 = if (core_) |core| core.getProcessInfo(.foreground_pid) else null;

        try s.beginObject();
        try s.objectField("type");
        try s.write("surface");
        try s.objectField("id");
        try writeId(s, if (core_) |core| core.id else null);
        try s.objectField("pid");
        try s.write(pid);
        try s.objectField("fg_pid");
        try s.write(fg_pid);

        try s.objectField("fg_comm");
        var comm_buf: [procinfo.comm_buf_len]u8 = undefined;
        try writeText(s, self.alloc, if (fg_pid) |p| procinfo.comm(&comm_buf, p) else null);

        try s.objectField("fg_cmdline");
        const cmdline: ?[]u8 = if (fg_pid) |p| try procinfo.cmdline(self.alloc, p) else null;
        defer if (cmdline) |v| self.alloc.free(v);
        try writeArgv(s, self.alloc, cmdline);

        try s.objectField("title");
        try writeText(s, self.alloc, surface.getEffectiveTitle());

        // Prefer the shell-reported (OSC 7) directory: it is what the user
        // sees, and works for remote shells. Fall back to the foreground
        // process's, then the shell's, working directory.
        try s.objectField("cwd");
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        try writeText(s, self.alloc, surface.getPwd() orelse cwd: {
            if (fg_pid) |p| if (procinfo.cwd(&cwd_buf, p)) |v| break :cwd v;
            if (pid) |p| if (procinfo.cwd(&cwd_buf, p)) |v| break :cwd v;
            break :cwd null;
        });

        try s.objectField("focused");
        try s.write(self.focused == surface);
        try s.endObject();
    }
};

/// Write the split tree rooted at the tree's root (or null for an empty
/// tree). Splits are written as spec.zig split nodes; each leaf view is
/// written by `leaf.write(s, view)`.
fn writeTree(
    comptime Tree: type,
    s: *Stringify,
    tree: *const Tree,
    leaf: anytype,
) WriteError!void {
    if (tree.nodes.len == 0) return try s.write(null);
    try writeNode(Tree, s, tree, .root, leaf);
}

fn writeNode(
    comptime Tree: type,
    s: *Stringify,
    tree: *const Tree,
    handle: Tree.Node.Handle,
    leaf: anytype,
) WriteError!void {
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| try leaf.write(s, view),
        .split => |split| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("split");
            try s.objectField("layout");
            try s.write(@tagName(split.layout));
            try s.objectField("ratio");
            try s.write(roundRatio(split.ratio));
            try s.objectField("left");
            try writeNode(Tree, s, tree, split.left, leaf);
            try s.objectField("right");
            try writeNode(Tree, s, tree, split.right, leaf);
            try s.endObject();
        },
    }
}

/// Ratios are f16; print them with 4 decimals (enough to round-trip through
/// f16 for any useful split) instead of the f16's full binary expansion.
fn roundRatio(ratio: f16) f64 {
    return @round(@as(f64, ratio) * 10_000) / 10_000;
}

/// Write a surface id as a "0x%016x" string, or null.
fn writeId(s: *Stringify, id: ?u64) Stringify.Error!void {
    const v = id orelse return try s.write(null);
    try s.print("\"0x{x:0>16}\"", .{v});
}

/// Write an optional string, replacing invalid UTF-8 (possible in titles,
/// paths and command lines) with U+FFFD so it is always a JSON string.
fn writeText(s: *Stringify, alloc: Allocator, text: ?[]const u8) WriteError!void {
    const v = text orelse return try s.write(null);
    if (std.unicode.utf8ValidateSlice(v)) return try s.write(v);
    const fixed = try std.fmt.allocPrint(alloc, "{f}", .{std.unicode.fmtUtf8(v)});
    defer alloc.free(fixed);
    try s.write(fixed);
}

/// Write a raw NUL-separated command line as an array of strings, or null.
fn writeArgv(s: *Stringify, alloc: Allocator, raw: ?[]const u8) WriteError!void {
    const v = raw orelse return try s.write(null);
    try s.beginArray();
    var it = procinfo.args(v);
    while (it.next()) |arg| try writeText(s, alloc, arg);
    try s.endArray();
}

/// Parse an ApplyLayout spec. Everything is allocated in `arena`. On
/// error.InvalidSpec a human-readable reason, prefixed with the JSON path of
/// the offending value, is written to `diag`.
///
/// Only checks that are possible without the live application happen here:
/// shape and types, hex ids, ratio range, non-empty window and tab lists,
/// unique `new` names, surface ids used at most once, and that `focus` and
/// `zoomed` refer to leaves of the spec (of the same tab for `zoomed`).
pub fn parseSpec(arena: Allocator, json: []const u8, diag: *std.Io.Writer) ParseError!spec.Spec {
    var p: Parser = .{ .arena = arena, .diag = diag, .root = "spec" };
    const root = try p.parseJson(json);
    const obj = try p.object(root);

    if (field(obj, "version")) |v| {
        const mark = try p.pushField("version");
        if (v != .integer or v.integer != spec.version)
            return p.fail("unsupported version, expected {d}", .{spec.version});
        p.pop(mark);
    }

    var result: spec.Spec = .{ .windows = &.{} };
    {
        const v = try p.required(obj, "windows");
        const mark = try p.pushField("windows");
        const items = try p.array(v);
        if (items.len == 0) return p.fail("must contain at least one window", .{});
        const windows = try arena.alloc(spec.Window, items.len);
        for (items, windows, 0..) |item, *window, i| {
            const item_mark = try p.pushIndex(i);
            window.* = try p.parseWindow(item);
            p.pop(item_mark);
        }
        result.windows = windows;
        p.pop(mark);
    }

    if (field(obj, "focus")) |v| {
        const mark = try p.pushField("focus");
        const ref = try p.parseRef(v);
        if (p.leafTab(ref) == null) return p.failUnknownRef(ref, "the layout");
        result.focus = ref;
        p.pop(mark);
    }

    return result;
}

/// Parse ApplyLayout options: {"allow_close":bool,"dry_run":bool}. An empty
/// (or all-whitespace) string or `null` means the defaults.
pub fn parseOptions(arena: Allocator, json: []const u8, diag: *std.Io.Writer) ParseError!spec.Options {
    var result: spec.Options = .{};
    if (std.mem.trim(u8, json, &std.ascii.whitespace).len == 0) return result;

    var p: Parser = .{ .arena = arena, .diag = diag, .root = "options" };
    // Option errors read "options.dry_run: …" to set them apart from spec
    // errors.
    _ = try p.pushField("options");
    const root = try p.parseJson(json);
    if (root == .null) return result;
    const obj = try p.object(root);
    inline for (.{ "allow_close", "dry_run" }) |name| {
        if (field(obj, name)) |v| {
            const mark = try p.pushField(name);
            if (v != .bool) return p.fail("must be a boolean", .{});
            @field(result, name) = v.bool;
            p.pop(mark);
        }
    }
    return result;
}

/// Returns the value of an object field, treating `null` like a missing
/// field.
fn field(obj: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    const v = obj.get(name) orelse return null;
    return if (v == .null) null else v;
}

/// Parse a surface id: "0x" followed by 1 to 16 hex digits, non-zero.
fn parseHexId(text: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, text, "0x")) return null;
    const digits = text[2..];
    if (digits.len == 0 or digits.len > 16) return null;
    for (digits) |ch| if (!std.ascii.isHex(ch)) return null;
    const id = std.fmt.parseInt(u64, digits, 16) catch return null;
    return if (id == 0) null else id;
}

const Parser = struct {
    arena: Allocator,
    diag: *std.Io.Writer,

    /// Name of the document, shown when an error is about the root value.
    root: []const u8,

    /// JSON path of the value being parsed, e.g. "windows[0].tabs[1].tree".
    path: std.ArrayList(u8) = .empty,

    /// Number of tabs parsed so far; identifies the tab containing a leaf.
    tab_count: usize = 0,

    /// Existing surface ids and `new` leaf names used in the spec, mapped
    /// to the tab (see tab_count) containing them.
    ids: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    names: std.StringHashMapUnmanaged(usize) = .empty,

    fn parseJson(self: *Parser, json: []const u8) ParseError!std.json.Value {
        var scanner: std.json.Scanner = .initCompleteInput(self.arena, json);
        var diagnostics: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diagnostics);
        return std.json.parseFromTokenSourceLeaky(
            std.json.Value,
            self.arena,
            &scanner,
            .{ .max_value_len = json.len },
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                try self.diag.print("{s}: invalid JSON at line {d}, column {d}: {t}", .{
                    self.root,
                    diagnostics.getLine(),
                    diagnostics.getColumn(),
                    err,
                });
                return error.InvalidSpec;
            },
        };
    }

    /// Report `fmt` at the current path and return error.InvalidSpec.
    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        const where = if (self.path.items.len == 0) self.root else self.path.items;
        self.diag.print("{s}: ", .{where}) catch return error.WriteFailed;
        self.diag.print(fmt, args) catch return error.WriteFailed;
        return error.InvalidSpec;
    }

    fn failUnknownRef(self: *Parser, ref: spec.Ref, scope: []const u8) ParseError {
        return switch (ref) {
            .id => |id| self.fail("surface 0x{x:0>16} is not in {s}", .{ id, scope }),
            .name => |name| self.fail("no new surface named \"{s}\" in {s}", .{ name, scope }),
        };
    }

    fn pushField(self: *Parser, name: []const u8) Allocator.Error!usize {
        const mark = self.path.items.len;
        if (mark > 0) try self.path.append(self.arena, '.');
        try self.path.appendSlice(self.arena, name);
        return mark;
    }

    fn pushIndex(self: *Parser, i: usize) Allocator.Error!usize {
        const mark = self.path.items.len;
        try self.path.print(self.arena, "[{d}]", .{i});
        return mark;
    }

    fn pop(self: *Parser, mark: usize) void {
        self.path.shrinkRetainingCapacity(mark);
    }

    fn object(self: *Parser, v: std.json.Value) ParseError!std.json.ObjectMap {
        if (v != .object) return self.fail("must be an object", .{});
        return v.object;
    }

    fn array(self: *Parser, v: std.json.Value) ParseError![]const std.json.Value {
        if (v != .array) return self.fail("must be an array", .{});
        return v.array.items;
    }

    fn string(self: *Parser, v: std.json.Value) ParseError![]const u8 {
        if (v != .string) return self.fail("must be a string", .{});
        return v.string;
    }

    /// A string passed on to C (argv, paths, titles): copied with a NUL
    /// terminator, so it must not contain NUL itself.
    fn stringZ(self: *Parser, v: std.json.Value) ParseError![:0]const u8 {
        const text = try self.string(v);
        if (std.mem.indexOfScalar(u8, text, 0) != null)
            return self.fail("must not contain NUL characters", .{});
        return try self.arena.dupeSentinel(u8, text, 0);
    }

    /// Like `field`, but a missing field is an error reported at the
    /// object's path.
    fn required(self: *Parser, obj: std.json.ObjectMap, name: []const u8) ParseError!std.json.Value {
        return obj.get(name) orelse self.fail("missing required field \"{s}\"", .{name});
    }

    /// The tab containing the leaf `ref` refers to, if it is in the spec.
    fn leafTab(self: *Parser, ref: spec.Ref) ?usize {
        return switch (ref) {
            .id => |id| self.ids.get(id),
            .name => |name| self.names.get(name),
        };
    }

    fn parseWindow(self: *Parser, v: std.json.Value) ParseError!spec.Window {
        const obj = try self.object(v);
        var result: spec.Window = .{ .tabs = &.{} };

        if (field(obj, "id")) |id| {
            const mark = try self.pushField("id");
            if (id != .integer or id.integer <= 0 or id.integer > std.math.maxInt(c_uint))
                return self.fail("must be a window id (a positive integer)", .{});
            result.id = @intCast(id.integer);
            self.pop(mark);
        }

        {
            const tabs_v = try self.required(obj, "tabs");
            const mark = try self.pushField("tabs");
            const items = try self.array(tabs_v);
            if (items.len == 0) return self.fail("must contain at least one tab", .{});
            const tabs = try self.arena.alloc(spec.Tab, items.len);
            for (items, tabs, 0..) |item, *tab, i| {
                const item_mark = try self.pushIndex(i);
                tab.* = try self.parseTab(item);
                self.pop(item_mark);
            }
            result.tabs = tabs;
            self.pop(mark);
        }

        if (field(obj, "selected_tab")) |sel| {
            const mark = try self.pushField("selected_tab");
            if (sel != .integer or sel.integer < 0 or sel.integer >= result.tabs.len)
                return self.fail("must be a tab index in [0, {d})", .{result.tabs.len});
            result.selected_tab = @intCast(sel.integer);
            self.pop(mark);
        }

        return result;
    }

    fn parseTab(self: *Parser, v: std.json.Value) ParseError!spec.Tab {
        const obj = try self.object(v);
        const tab = self.tab_count;
        self.tab_count += 1;

        var result: spec.Tab = .{ .root = undefined };
        {
            const tree = try self.required(obj, "tree");
            const mark = try self.pushField("tree");
            result.root = try self.parseNode(tree, tab);
            self.pop(mark);
        }

        if (field(obj, "zoomed")) |zoomed| {
            const mark = try self.pushField("zoomed");
            const ref = try self.parseRef(zoomed);
            if (self.leafTab(ref) != tab) return self.failUnknownRef(ref, "this tab");
            result.zoomed = ref;
            self.pop(mark);
        }

        return result;
    }

    fn parseNode(self: *Parser, v: std.json.Value, tab: usize) ParseError!*const spec.Node {
        const obj = try self.object(v);
        const node = try self.arena.create(spec.Node);

        const type_v = try self.required(obj, "type");
        const type_mark = try self.pushField("type");
        const kind = try self.string(type_v);
        const is_split = std.mem.eql(u8, kind, "split");
        if (!is_split and !std.mem.eql(u8, kind, "surface"))
            return self.fail("must be \"split\" or \"surface\"", .{});
        self.pop(type_mark);

        node.* = if (is_split)
            .{ .split = try self.parseSplit(obj, tab) }
        else
            .{ .surface = try self.parseLeaf(obj, tab) };
        return node;
    }

    fn parseSplit(self: *Parser, obj: std.json.ObjectMap, tab: usize) ParseError!spec.Split {
        var result: spec.Split = .{ .layout = undefined, .left = undefined, .right = undefined };

        {
            const layout_v = try self.required(obj, "layout");
            const mark = try self.pushField("layout");
            const text = if (layout_v == .string) layout_v.string else "";
            result.layout = std.meta.stringToEnum(spec.Layout, text) orelse
                return self.fail("must be \"horizontal\" or \"vertical\"", .{});
            self.pop(mark);
        }

        if (field(obj, "ratio")) |ratio_v| {
            const mark = try self.pushField("ratio");
            const ratio: f64 = switch (ratio_v) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => return self.fail("must be a number in (0,1)", .{}),
            };
            if (!(ratio > 0 and ratio < 1)) return self.fail("must be in (0,1), got {d}", .{ratio});
            // Keep ratios that are too close to 0 or 1 for f16 inside (0,1).
            result.ratio = std.math.clamp(
                @as(f16, @floatCast(ratio)),
                std.math.floatMin(f16),
                1 - std.math.floatEps(f16) / 2,
            );
            self.pop(mark);
        }

        inline for (.{ "left", "right" }) |side| {
            const child = try self.required(obj, side);
            const mark = try self.pushField(side);
            @field(result, side) = try self.parseNode(child, tab);
            self.pop(mark);
        }

        return result;
    }

    fn parseLeaf(self: *Parser, obj: std.json.ObjectMap, tab: usize) ParseError!spec.Leaf {
        const id_v = field(obj, "id");
        const new_v = field(obj, "new");
        if (id_v != null and new_v != null)
            return self.fail("surface must have either \"id\" or \"new\", not both", .{});

        if (id_v) |v| {
            const mark = try self.pushField("id");
            const text = if (v == .string) v.string else "";
            const id = parseHexId(text) orelse
                return self.fail("must be a surface id string like \"0x0123456789abcdef\"", .{});
            const entry = try self.ids.getOrPut(self.arena, id);
            if (entry.found_existing)
                return self.fail("surface 0x{x:0>16} appears more than once", .{id});
            entry.value_ptr.* = tab;
            self.pop(mark);
            return .{ .existing = id };
        }

        if (new_v) |v| {
            const mark = try self.pushField("new");
            const result = try self.parseNew(v, tab);
            self.pop(mark);
            return .{ .new = result };
        }

        // GetLayout reports surfaces that aren't initialized yet with a null
        // id; they can't be referenced until they have one.
        if (obj.contains("id")) {
            _ = try self.pushField("id");
            return self.fail("surface has no id yet; retry once it is initialized", .{});
        }
        return self.fail("surface must have \"id\" or \"new\"", .{});
    }

    fn parseNew(self: *Parser, v: std.json.Value, tab: usize) ParseError!spec.New {
        const obj = try self.object(v);
        var result: spec.New = .{ .name = undefined };

        {
            const name_v = try self.required(obj, "name");
            const mark = try self.pushField("name");
            const name = try self.string(name_v);
            if (name.len == 0) return self.fail("must not be empty", .{});
            if (std.mem.startsWith(u8, name, "0x"))
                return self.fail("must not start with \"0x\" (reserved for surface ids)", .{});
            const entry = try self.names.getOrPut(self.arena, name);
            if (entry.found_existing)
                return self.fail("new surface name \"{s}\" is used more than once", .{name});
            entry.value_ptr.* = tab;
            result.name = name;
            self.pop(mark);
        }

        if (field(obj, "command")) |command| {
            const mark = try self.pushField("command");
            result.command = switch (command) {
                .string => .{ .shell = try self.nonEmptyZ(command) },
                .array => |list| argv: {
                    if (list.items.len == 0) return self.fail("must not be empty", .{});
                    const argv = try self.arena.alloc([:0]const u8, list.items.len);
                    for (list.items, argv, 0..) |arg_v, *arg, i| {
                        const arg_mark = try self.pushIndex(i);
                        arg.* = try self.stringZ(arg_v);
                        self.pop(arg_mark);
                    }
                    if (argv[0].len == 0) {
                        _ = try self.pushIndex(0);
                        return self.fail("must not be empty", .{});
                    }
                    break :argv .{ .argv = argv };
                },
                else => return self.fail("must be an argv array of strings or a shell command string", .{}),
            };
            self.pop(mark);
        }

        if (field(obj, "cwd")) |cwd| {
            const mark = try self.pushField("cwd");
            result.cwd = try self.nonEmptyZ(cwd);
            self.pop(mark);
        }

        if (field(obj, "title")) |title| {
            const mark = try self.pushField("title");
            result.title = try self.stringZ(title);
            self.pop(mark);
        }

        return result;
    }

    fn nonEmptyZ(self: *Parser, v: std.json.Value) ParseError![:0]const u8 {
        const text = try self.stringZ(v);
        if (text.len == 0) return self.fail("must not be empty", .{});
        return text;
    }

    /// A ref is a surface id ("0x…") or a `new` leaf name.
    fn parseRef(self: *Parser, v: std.json.Value) ParseError!spec.Ref {
        const text = if (v == .string) v.string else "";
        if (std.mem.startsWith(u8, text, "0x")) {
            const id = parseHexId(text) orelse
                return self.fail("invalid surface id \"{s}\"", .{text});
            return .{ .id = id };
        }
        if (text.len == 0) return self.fail("must be a surface id (\"0x…\") or a new surface name", .{});
        return .{ .name = text };
    }
};

// Tests

const testing = std.testing;

fn expectParseError(json: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.InvalidSpec, parseSpec(arena.allocator(), json, &diag));
    try testing.expectEqualStrings(expected, diag.buffered());
}

test "layout: parseOptions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [256]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);

    try testing.expectEqual(spec.Options{}, try parseOptions(alloc, "", &diag));
    try testing.expectEqual(spec.Options{}, try parseOptions(alloc, " \n", &diag));
    try testing.expectEqual(spec.Options{}, try parseOptions(alloc, "null", &diag));
    try testing.expectEqual(spec.Options{}, try parseOptions(alloc, "{}", &diag));
    try testing.expectEqual(
        spec.Options{ .allow_close = true },
        try parseOptions(alloc, "{\"allow_close\":true,\"dry_run\":null}", &diag),
    );
    try testing.expectEqual(
        spec.Options{ .allow_close = false, .dry_run = true },
        try parseOptions(alloc, "{\"dry_run\":true,\"unknown\":[1]}", &diag),
    );
    try testing.expectEqual(0, diag.end);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "[]", "options: must be an object" },
        .{ "{\"dry_run\":1}", "options.dry_run: must be a boolean" },
        .{ "{\"allow_close\":\"yes\"}", "options.allow_close: must be a boolean" },
        .{ "{", "options: invalid JSON at line 1, column 2: UnexpectedEndOfInput" },
        .{ "{} x", "options: invalid JSON at line 1, column 4: SyntaxError" },
    };
    for (cases) |case| {
        diag.end = 0;
        try testing.expectError(error.InvalidSpec, parseOptions(alloc, case[0], &diag));
        try testing.expectEqualStrings(case[1], diag.buffered());
    }
}

test "layout: parseSpec minimal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);

    const s = try parseSpec(
        arena.allocator(),
        \\{"windows":[{"tabs":[{"tree":{"type":"surface","id":"0xAbC"}}]}]}
    ,
        &diag,
    );
    try testing.expectEqual(1, s.windows.len);
    try testing.expectEqual(null, s.windows[0].id);
    try testing.expectEqual(null, s.windows[0].selected_tab);
    try testing.expectEqual(null, s.focus);
    try testing.expectEqual(1, s.windows[0].tabs.len);
    try testing.expectEqual(null, s.windows[0].tabs[0].zoomed);
    try testing.expectEqual(spec.Leaf{ .existing = 0xabc }, s.windows[0].tabs[0].root.surface);
}

test "layout: parseSpec full" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);

    const s = try parseSpec(arena.allocator(),
        \\{"version":1,"focus":"build",
        \\ "windows":[
        \\  {"id":3,"selected_tab":1,"tabs":[
        \\    {"tree":{"type":"surface","id":"0x00000000000000ff"}},
        \\    {"zoomed":"0x10","tree":{"type":"split","layout":"vertical","ratio":0.25,
        \\      "left":{"type":"surface","id":"0x10"},
        \\      "right":{"type":"split","layout":"horizontal",
        \\        "left":{"type":"surface","new":{"name":"build","command":["make","-j8"],
        \\                                         "cwd":"/tmp","title":"Build"}},
        \\        "right":{"type":"surface","new":{"name":"sh","command":"htop -d 5"}}}}}]},
        \\  {"tabs":[{"tree":{"type":"surface","new":{"name":"plain"}}}]}]}
    , &diag);

    try testing.expectEqualDeep(spec.Ref{ .name = "build" }, s.focus.?);
    try testing.expectEqual(2, s.windows.len);

    const w0 = s.windows[0];
    try testing.expectEqual(3, w0.id.?);
    try testing.expectEqual(1, w0.selected_tab.?);
    try testing.expectEqual(2, w0.tabs.len);
    try testing.expectEqual(spec.Leaf{ .existing = 0xff }, w0.tabs[0].root.surface);
    try testing.expectEqual(spec.Ref{ .id = 0x10 }, w0.tabs[1].zoomed.?);

    const outer = w0.tabs[1].root.split;
    try testing.expectEqual(.vertical, outer.layout);
    try testing.expectEqual(@as(f16, 0.25), outer.ratio);
    try testing.expectEqual(spec.Leaf{ .existing = 0x10 }, outer.left.surface);

    const inner = outer.right.split;
    try testing.expectEqual(.horizontal, inner.layout);
    try testing.expectEqual(@as(f16, 0.5), inner.ratio);

    const build = inner.left.surface.new;
    try testing.expectEqualStrings("build", build.name);
    try testing.expectEqual(2, build.command.?.argv.len);
    try testing.expectEqualStrings("make", build.command.?.argv[0]);
    try testing.expectEqualStrings("-j8", build.command.?.argv[1]);
    try testing.expectEqualStrings("/tmp", build.cwd.?);
    try testing.expectEqualStrings("Build", build.title.?);

    const sh = inner.right.surface.new;
    try testing.expectEqualStrings("sh", sh.name);
    try testing.expectEqualStrings("htop -d 5", sh.command.?.shell);
    try testing.expectEqual(null, sh.cwd);
    try testing.expectEqual(null, sh.title);

    const plain = s.windows[1].tabs[0].root.surface.new;
    try testing.expectEqualStrings("plain", plain.name);
    try testing.expectEqual(null, plain.command);
    try testing.expectEqual(null, s.windows[1].id);
}

test "layout: parseSpec accepts a GetLayout document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);

    const s = try parseSpec(arena.allocator(),
        \\{"version":1,"focused_surface":"0x00000000deadbeef","windows":[
        \\ {"id":1,"active":true,"quick_terminal":false,"title":"~","selected_tab":0,"tabs":[
        \\  {"index":0,"selected":true,"title":"~","zoomed":null,"tree":
        \\   {"type":"split","layout":"horizontal","ratio":0.6667,
        \\    "left":{"type":"surface","id":"0x00000000deadbeef","pid":10,"fg_pid":12,
        \\            "fg_comm":"nvim","fg_cmdline":["nvim","x.zig"],"title":"x.zig",
        \\            "cwd":"/home/u","focused":true},
        \\    "right":{"type":"surface","id":"0x0000000000000002","pid":11,"fg_pid":11,
        \\             "fg_comm":"bash","fg_cmdline":["bash"],"title":"~","cwd":null,
        \\             "focused":false}}}]}]}
    , &diag);

    const w = s.windows[0];
    try testing.expectEqual(1, w.id.?);
    try testing.expectEqual(0, w.selected_tab.?);
    try testing.expectEqual(null, w.tabs[0].zoomed);
    const split = w.tabs[0].root.split;
    try testing.expectEqual(.horizontal, split.layout);
    try testing.expectEqual(@as(f16, 0.6667), split.ratio);
    try testing.expectEqual(spec.Leaf{ .existing = 0xdeadbeef }, split.left.surface);
    try testing.expectEqual(spec.Leaf{ .existing = 2 }, split.right.surface);
}

test "layout: parseSpec errors" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "spec: invalid JSON at line 1, column 1: UnexpectedEndOfInput" },
        .{ "{\"windows\":[],}", "spec: invalid JSON at line 1, column 15: SyntaxError" },
        .{ "{\"windows\":[],\"windows\":[]}", "spec: invalid JSON at line 1, column 27: DuplicateField" },
        .{ "[]", "spec: must be an object" },
        .{ "{}", "spec: missing required field \"windows\"" },
        .{ "{\"version\":2,\"windows\":[]}", "version: unsupported version, expected 1" },
        .{ "{\"windows\":{}}", "windows: must be an array" },
        .{ "{\"windows\":[]}", "windows: must contain at least one window" },
        .{ "{\"windows\":[1]}", "windows[0]: must be an object" },
        .{ "{\"windows\":[{}]}", "windows[0]: missing required field \"tabs\"" },
        .{ "{\"windows\":[{\"tabs\":[]}]}", "windows[0].tabs: must contain at least one tab" },
        .{ "{\"windows\":[{\"id\":0,\"tabs\":[]}]}", "windows[0].id: must be a window id (a positive integer)" },
        .{ "{\"windows\":[{\"id\":\"1\",\"tabs\":[]}]}", "windows[0].id: must be a window id (a positive integer)" },
        .{ "{\"windows\":[{\"tabs\":[{}]}]}", "windows[0].tabs[0]: missing required field \"tree\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":null}]}]}", "windows[0].tabs[0].tree: must be an object" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{}}]}]}", "windows[0].tabs[0].tree: missing required field \"type\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"leaf\"}}]}]}", "windows[0].tabs[0].tree.type: must be \"split\" or \"surface\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\"}}]}]}", "windows[0].tabs[0].tree: surface must have \"id\" or \"new\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":null}}]}]}", "windows[0].tabs[0].tree.id: surface has no id yet; retry once it is initialized" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1\",\"new\":{\"name\":\"a\"}}}]}]}", "windows[0].tabs[0].tree: surface must have either \"id\" or \"new\", not both" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":1}}]}]}", "windows[0].tabs[0].tree.id: must be a surface id string like \"0x0123456789abcdef\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x\"}}]}]}", "windows[0].tabs[0].tree.id: must be a surface id string like \"0x0123456789abcdef\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x0\"}}]}]}", "windows[0].tabs[0].tree.id: must be a surface id string like \"0x0123456789abcdef\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1_0\"}}]}]}", "windows[0].tabs[0].tree.id: must be a surface id string like \"0x0123456789abcdef\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x10000000000000000\"}}]}]}", "windows[0].tabs[0].tree.id: must be a surface id string like \"0x0123456789abcdef\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}},{\"tree\":{\"type\":\"surface\",\"id\":\"0x01\"}}]}]}", "windows[0].tabs[1].tree.id: surface 0x0000000000000001 appears more than once" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"left\":{},\"right\":{}}}]}]}", "windows[0].tabs[0].tree: missing required field \"layout\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"layout\":\"diagonal\"}}]}]}", "windows[0].tabs[0].tree.layout: must be \"horizontal\" or \"vertical\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"layout\":\"vertical\",\"ratio\":\"half\"}}]}]}", "windows[0].tabs[0].tree.ratio: must be a number in (0,1)" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"layout\":\"vertical\",\"ratio\":1}}]}]}", "windows[0].tabs[0].tree.ratio: must be in (0,1), got 1" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"layout\":\"vertical\",\"ratio\":-0.5}}]}]}", "windows[0].tabs[0].tree.ratio: must be in (0,1), got -0.5" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"layout\":\"vertical\"}}]}]}", "windows[0].tabs[0].tree: missing required field \"left\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"split\",\"layout\":\"vertical\",\"left\":{\"type\":\"surface\",\"id\":\"0x1\"},\"right\":{\"type\":\"split\",\"layout\":\"horizontal\",\"ratio\":2}}}]}]}", "windows[0].tabs[0].tree.right.ratio: must be in (0,1), got 2" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":\"a\"}}]}]}", "windows[0].tabs[0].tree.new: must be an object" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{}}}]}]}", "windows[0].tabs[0].tree.new: missing required field \"name\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"\"}}}]}]}", "windows[0].tabs[0].tree.new.name: must not be empty" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"0x1\"}}}]}]}", "windows[0].tabs[0].tree.new.name: must not start with \"0x\" (reserved for surface ids)" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\"}}}]},{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\"}}}]}]}", "windows[1].tabs[0].tree.new.name: new surface name \"a\" is used more than once" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"command\":[]}}}]}]}", "windows[0].tabs[0].tree.new.command: must not be empty" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"command\":[\"\"]}}}]}]}", "windows[0].tabs[0].tree.new.command[0]: must not be empty" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"command\":[\"ls\",3]}}}]}]}", "windows[0].tabs[0].tree.new.command[1]: must be a string" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"command\":\"\"}}}]}]}", "windows[0].tabs[0].tree.new.command: must not be empty" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"command\":{}}}}]}]}", "windows[0].tabs[0].tree.new.command: must be an argv array of strings or a shell command string" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"cwd\":\"/a\\u0000b\"}}}]}]}", "windows[0].tabs[0].tree.new.cwd: must not contain NUL characters" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"cwd\":\"\"}}}]}]}", "windows[0].tabs[0].tree.new.cwd: must not be empty" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"new\":{\"name\":\"a\",\"title\":5}}}]}]}", "windows[0].tabs[0].tree.new.title: must be a string" },
        .{ "{\"windows\":[{\"selected_tab\":1,\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}}]}]}", "windows[0].selected_tab: must be a tab index in [0, 1)" },
        .{ "{\"windows\":[{\"tabs\":[{\"zoomed\":\"\",\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}}]}]}", "windows[0].tabs[0].zoomed: must be a surface id (\"0x…\") or a new surface name" },
        .{ "{\"windows\":[{\"tabs\":[{\"zoomed\":\"0xg\",\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}}]}]}", "windows[0].tabs[0].zoomed: invalid surface id \"0xg\"" },
        .{ "{\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}},{\"zoomed\":\"0x1\",\"tree\":{\"type\":\"surface\",\"id\":\"0x2\"}}]}]}", "windows[0].tabs[1].zoomed: surface 0x0000000000000001 is not in this tab" },
        .{ "{\"windows\":[{\"tabs\":[{\"zoomed\":\"x\",\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}}]}]}", "windows[0].tabs[0].zoomed: no new surface named \"x\" in this tab" },
        .{ "{\"focus\":\"0x2\",\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}}]}]}", "focus: surface 0x0000000000000002 is not in the layout" },
        .{ "{\"focus\":7,\"windows\":[{\"tabs\":[{\"tree\":{\"type\":\"surface\",\"id\":\"0x1\"}}]}]}", "focus: must be a surface id (\"0x…\") or a new surface name" },
    };
    for (cases) |case| expectParseError(case[0], case[1]) catch |err| {
        std.debug.print("case: {s}\n", .{case[0]});
        return err;
    };
}

test "layout: parseSpec clamps ratios to f16 inside (0,1)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);

    const s = try parseSpec(arena.allocator(),
        \\{"windows":[{"tabs":[{"tree":{"type":"split","layout":"horizontal","ratio":0.99999,
        \\  "left":{"type":"split","layout":"vertical","ratio":1e-9,
        \\    "left":{"type":"surface","id":"0x1"},"right":{"type":"surface","id":"0x2"}},
        \\  "right":{"type":"surface","id":"0x3"}}}]}]}
    , &diag);
    const outer = s.windows[0].tabs[0].root.split;
    try testing.expect(outer.ratio > 0.999 and outer.ratio < 1);
    const inner = outer.left.split;
    try testing.expect(inner.ratio > 0 and inner.ratio < 0.001);
}

const TestView = struct {
    id: u64,

    pub fn ref(self: *TestView) *TestView {
        return self;
    }

    pub fn unref(_: *TestView) void {}

    const Leaf = struct {
        pub fn write(_: Leaf, s: *Stringify, view: *TestView) WriteError!void {
            try s.beginObject();
            try s.objectField("type");
            try s.write("surface");
            try s.objectField("id");
            try writeId(s, view.id);
            try s.objectField("pid");
            try s.write(null);
            try s.endObject();
        }
    };
};

const TestTree = @import("../../../datastruct/split_tree.zig").SplitTree(TestView);

test "layout: writeTree round-trips through parseSpec" {
    var a: TestView = .{ .id = 0xa };
    var b: TestView = .{ .id = 0xb };
    var c: TestView = .{ .id = 0xc };
    // horizontal(1/3: a | vertical(b / c))
    const nodes = [_]TestTree.Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 1.0 / 3.0, .left = @fromBackingInt(@intCast(1)), .right = @fromBackingInt(@intCast(2)) } },
        .{ .leaf = &a },
        .{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = @fromBackingInt(@intCast(3)), .right = @fromBackingInt(@intCast(4)) } },
        .{ .leaf = &b },
        .{ .leaf = &c },
    };
    const tree: TestTree = .{ .arena = undefined, .nodes = &nodes, .zoomed = null };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var s: Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("windows");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("tabs");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("tree");
    try writeTree(TestTree, &s, &tree, TestView.Leaf{});
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();
    try s.endObject();

    try testing.expectEqualStrings(
        \\{"windows":[{"tabs":[{"tree":{"type":"split","layout":"horizontal","ratio":0.3333,"left":{"type":"surface","id":"0x000000000000000a","pid":null},"right":{"type":"split","layout":"vertical","ratio":0.5,"left":{"type":"surface","id":"0x000000000000000b","pid":null},"right":{"type":"surface","id":"0x000000000000000c","pid":null}}}}]}]}
    , out.written());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&buf);
    const parsed = try parseSpec(arena.allocator(), out.written(), &diag);
    const root = parsed.windows[0].tabs[0].root.split;
    try testing.expectEqual(.horizontal, root.layout);
    try testing.expectEqual(@as(f16, 1.0 / 3.0), root.ratio);
    try testing.expectEqual(spec.Leaf{ .existing = 0xa }, root.left.surface);
    try testing.expectEqual(.vertical, root.right.split.layout);
    try testing.expectEqual(spec.Leaf{ .existing = 0xb }, root.right.split.left.surface);
    try testing.expectEqual(spec.Leaf{ .existing = 0xc }, root.right.split.right.surface);

    // An empty tree is written as null.
    out.clearRetainingCapacity();
    s = .{ .writer = &out.writer };
    try writeTree(TestTree, &s, &TestTree.empty, TestView.Leaf{});
    try testing.expectEqualStrings("null", out.written());
}

test "layout: writeId, writeText, writeArgv" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var s: Stringify = .{ .writer = &out.writer };

    try s.beginArray();
    try writeId(&s, 0x1234);
    try writeId(&s, std.math.maxInt(u64));
    try writeId(&s, null);
    try writeText(&s, testing.allocator, "a \"q\"\n\\ é");
    try writeText(&s, testing.allocator, "bad\xffbyte");
    try writeText(&s, testing.allocator, null);
    try writeArgv(&s, testing.allocator, "vim\x00a b\x00\x00");
    try writeArgv(&s, testing.allocator, null);
    try s.endArray();

    try testing.expectEqualStrings(
        "[\"0x0000000000001234\",\"0xffffffffffffffff\",null," ++
            "\"a \\\"q\\\"\\n\\\\ é\",\"bad\u{fffd}byte\",null," ++
            "[\"vim\",\"a b\",\"\"],null]",
        out.written(),
    );
}
