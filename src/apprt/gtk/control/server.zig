//! The `dev.tony.Ghostty.Control` D-Bus interface, exported on the
//! GApplication's own object path (bus name = application id).
//!
//! Methods:
//!
//!   GetLayout() -> (s json)
//!   ApplyLayout(s spec_json, s options_json) -> (s result_json)
//!   Focus(t surface_id) -> ()
//!
//! All handlers run on the GTK main thread (GDBus dispatches method calls on
//! the main context that registered the object) and never block it:
//! ApplyLayout replies asynchronously once every newly created surface has a
//! core surface id (or after `create_timeout_ms`, reporting null for the ids
//! that are still missing).

const std = @import("std");
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
const layout = @import("layout.zig");
const apply = @import("apply.zig");

const log = std.log.scoped(.gtk_control);

pub const interface_name = "dev.tony.Ghostty.Control";

/// How long ApplyLayout waits for new surfaces to get a core surface id.
pub const create_timeout_ms = 5000;

/// D-Bus error names returned by the interface.
pub const errors = struct {
    pub const invalid_layout = interface_name ++ ".Error.InvalidLayout";
    pub const unknown_surface = interface_name ++ ".Error.UnknownSurface";
    pub const failed = interface_name ++ ".Error.Failed";
};

const introspection_xml =
    \\<node>
    \\  <interface name="dev.tony.Ghostty.Control">
    \\    <method name="GetLayout">
    \\      <arg type="s" name="json" direction="out"/>
    \\    </method>
    \\    <method name="ApplyLayout">
    \\      <arg type="s" name="spec" direction="in"/>
    \\      <arg type="s" name="options" direction="in"/>
    \\      <arg type="s" name="result" direction="out"/>
    \\    </method>
    \\    <method name="Focus">
    \\      <arg type="t" name="surface" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

/// Mirror of `GDBusInterfaceVTable` with nullable padding so it can be
/// zero-initialized; the generated binding declares the padding non-null.
const VTable = extern struct {
    method_call: ?gio.DBusInterfaceMethodCallFunc,
    get_property: ?gio.DBusInterfaceGetPropertyFunc = null,
    set_property: ?gio.DBusInterfaceSetPropertyFunc = null,
    padding: [8]?*anyopaque = @splat(null),

    comptime {
        std.debug.assert(@sizeOf(VTable) == @sizeOf(gio.DBusInterfaceVTable));
    }
};

const vtable: VTable = .{ .method_call = &methodCall };

/// Registration state of the interface, owned by the Application.
pub const Server = struct {
    registration: c_uint = 0,

    /// Export the interface on `path`. Failure is logged, not fatal: the
    /// rest of the application works without the control interface.
    pub fn register(
        self: *Server,
        app: *Application,
        connection: *gio.DBusConnection,
        path: [*:0]const u8,
    ) void {
        std.debug.assert(self.registration == 0);

        var err_: ?*glib.Error = null;
        const node = gio.DBusNodeInfo.newForXml(introspection_xml, &err_) orelse {
            logError("parsing introspection data", err_);
            return;
        };
        defer node.unref();
        const iface = node.lookupInterface(interface_name).?;

        // The application outlives the registration, so there is nothing
        // to free; the binding requires a non-null destroy notify.
        const noopDestroy = struct {
            fn f(_: ?*anyopaque) callconv(.c) void {}
        }.f;

        const id = connection.registerObject(
            path,
            iface,
            @ptrCast(&vtable),
            app,
            &noopDestroy,
            &err_,
        );
        if (id == 0) {
            logError("registering object", err_);
            return;
        }

        self.registration = id;
        log.debug("registered {s} at {s}", .{ interface_name, path });
    }

    pub fn unregister(self: *Server, connection: *gio.DBusConnection) void {
        if (self.registration == 0) return;
        if (connection.unregisterObject(self.registration) == 0) {
            log.warn("unable to unregister {s}", .{interface_name});
        }
        self.registration = 0;
    }

    fn logError(what: []const u8, err_: ?*glib.Error) void {
        const err = err_ orelse {
            log.warn("{s} failed for {s}", .{ what, interface_name });
            return;
        };
        defer err.free();
        log.warn("{s} failed for {s}: {s}", .{
            what,
            interface_name,
            err.f_message orelse "(no message)",
        });
    }
};

fn methodCall(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    ud: ?*anyopaque,
) callconv(.c) void {
    const app: *Application = @ptrCast(@alignCast(ud orelse return));
    const method = std.mem.span(method_name);

    // GDBus validates the method name and argument signature against the
    // introspection data before dispatching, so the names are exhaustive.
    if (std.mem.eql(u8, method, "GetLayout")) {
        getLayout(app, invocation);
    } else if (std.mem.eql(u8, method, "ApplyLayout")) {
        applyLayout(app, parameters, invocation);
    } else if (std.mem.eql(u8, method, "Focus")) {
        focus(app, parameters, invocation);
    } else {
        invocation.returnDbusError(
            "org.freedesktop.DBus.Error.UnknownMethod",
            "unknown method",
        );
    }
}

fn getLayout(app: *Application, invocation: *gio.DBusMethodInvocation) void {
    const alloc = app.allocator();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    layout.write(app, alloc, &aw.writer) catch |err| {
        returnError(alloc, invocation, errors.failed, "GetLayout failed: {s}", .{@errorName(err)});
        return;
    };
    aw.writer.writeByte(0) catch {
        returnError(alloc, invocation, errors.failed, "GetLayout failed: out of memory", .{});
        return;
    };
    const json = aw.written();
    returnString(invocation, json[0 .. json.len - 1 :0]);
}

fn focus(
    app: *Application,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
) void {
    var id: u64 = 0;
    parameters.get("(t)", &id);
    if (!app.presentSurface(id)) {
        returnError(app.allocator(), invocation, errors.unknown_surface, "no surface with id 0x{x:0>16}", .{id});
        return;
    }
    invocation.returnValue(null);
}

fn applyLayout(
    app: *Application,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
) void {
    var spec_json: [*:0]const u8 = undefined;
    var options_json: [*:0]const u8 = undefined;
    parameters.get("(&s&s)", &spec_json, &options_json);

    const pending = Pending.create(app.allocator(), invocation) catch {
        returnError(app.allocator(), invocation, errors.failed, "ApplyLayout failed: out of memory", .{});
        return;
    };
    pending.run(app, std.mem.span(spec_json), std.mem.span(options_json));
}

/// One in-flight ApplyLayout call. Owns the D-Bus invocation until it
/// replies, and an arena holding everything parsed/applied for the call.
const Pending = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    invocation: *gio.DBusMethodInvocation,
    ids: CreatedIds = .empty,
    closed: []const u64 = &.{},
    dry_run: bool = false,
    waits: []Wait = &.{},
    timeout: c_uint = 0,
    /// Human-readable reason for error.Invalid (arena memory).
    diag: []const u8 = "",

    /// A strong ref on a created surface plus its `init` signal handler.
    const Wait = struct {
        pending: *Pending,
        index: usize,
        surface: *Surface,
        handler: c_ulong = 0,
    };

    fn create(alloc: Allocator, invocation: *gio.DBusMethodInvocation) Allocator.Error!*Pending {
        const self = try alloc.create(Pending);
        self.* = .{
            .alloc = alloc,
            .arena = .init(alloc),
            .invocation = invocation,
        };
        return self;
    }

    fn destroy(self: *Pending) void {
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    /// Parse, apply and either reply immediately or start waiting for the
    /// created surfaces. Always consumes `self`, eventually.
    fn run(self: *Pending, app: *Application, spec_json: []const u8, options_json: []const u8) void {
        self.start(app, spec_json, options_json) catch |err| {
            self.fail(err);
            return;
        };
        if (self.ids.remaining == 0) {
            self.finish();
            return;
        }
        self.timeout = glib.timeoutAdd(create_timeout_ms, onTimeout, self);
    }

    const StartError = error{ Invalid, OutOfMemory, WriteFailed };

    fn start(self: *Pending, app: *Application, spec_json: []const u8, options_json: []const u8) StartError!void {
        const arena = self.arena.allocator();

        var diag: std.Io.Writer.Allocating = .init(arena);
        errdefer self.diag = diag.written();

        // The variant strings are owned by the invocation; copy them so
        // parsed slices (e.g. `new` names) outlive any reply ordering.
        const spec_copy = try arena.dupe(u8, spec_json);
        const options_copy = try arena.dupe(u8, options_json);

        const opts = layout.parseOptions(arena, options_copy, &diag.writer) catch |err| return switch (err) {
            error.InvalidSpec => error.Invalid,
            else => |e| e,
        };
        const s = layout.parseSpec(arena, spec_copy, &diag.writer) catch |err| return switch (err) {
            error.InvalidSpec => error.Invalid,
            else => |e| e,
        };
        const result = apply.apply(app, arena, s, opts, &diag.writer) catch |err| return switch (err) {
            error.InvalidLayout => error.Invalid,
            else => |e| e,
        };

        self.dry_run = opts.dry_run;
        self.closed = result.closed;
        self.ids = try .init(arena, result.created.len);
        self.waits = try arena.alloc(Wait, result.created.len);

        for (result.created, self.waits, 0..) |created, *wait, i| {
            self.ids.names[i] = created.name;
            wait.* = .{ .pending = self, .index = i, .surface = created.surface.ref() };
            if (created.surface.core()) |core| {
                _ = self.ids.resolve(i, core.id);
                continue;
            }
            wait.handler = Surface.signals.init.connect(
                created.surface,
                *Wait,
                onSurfaceInit,
                wait,
                .{},
            );
        }
    }

    fn onSurfaceInit(surface: *Surface, wait: *Wait) callconv(.c) void {
        const self = wait.pending;
        gobject.signalHandlerDisconnect(surface.as(gobject.Object), wait.handler);
        wait.handler = 0;
        const core = surface.core() orelse return;
        if (self.ids.resolve(wait.index, core.id)) self.finish();
    }

    fn onTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Pending = @ptrCast(@alignCast(ud.?));
        self.timeout = 0;
        log.warn("ApplyLayout: {} new surface(s) got no id within {}ms", .{
            self.ids.remaining,
            create_timeout_ms,
        });
        self.finish();
        return @intFromBool(false); // G_SOURCE_REMOVE
    }

    /// Reply with the result JSON and free everything.
    fn finish(self: *Pending) void {
        if (self.timeout != 0) {
            _ = glib.Source.remove(self.timeout);
            self.timeout = 0;
        }
        self.releaseWaits();

        var aw: std.Io.Writer.Allocating = .init(self.arena.allocator());
        self.ids.writeResult(&aw.writer, self.closed, self.dry_run) catch {
            self.fail(error.OutOfMemory);
            return;
        };
        aw.writer.writeByte(0) catch {
            self.fail(error.OutOfMemory);
            return;
        };
        const json = aw.written();
        returnString(self.invocation, json[0 .. json.len - 1 :0]);
        self.destroy();
    }

    fn releaseWaits(self: *Pending) void {
        for (self.waits) |*wait| {
            if (wait.handler != 0) {
                gobject.signalHandlerDisconnect(wait.surface.as(gobject.Object), wait.handler);
                wait.handler = 0;
            }
            wait.surface.unref();
        }
        self.waits = &.{};
    }

    /// Reply with an error and free everything.
    fn fail(self: *Pending, err: StartError) void {
        self.releaseWaits();
        switch (err) {
            error.Invalid => returnError(
                self.alloc,
                self.invocation,
                errors.invalid_layout,
                "{s}",
                .{if (self.diag.len > 0) self.diag else "invalid layout"},
            ),
            error.OutOfMemory, error.WriteFailed => returnError(
                self.alloc,
                self.invocation,
                errors.failed,
                "ApplyLayout failed: {s}",
                .{@errorName(err)},
            ),
        }
        self.destroy();
    }
};

/// Collects the ids of surfaces created by ApplyLayout as they appear and
/// renders the ApplyLayout result JSON. Pure, so it is unit tested.
const CreatedIds = struct {
    names: [][]const u8,
    ids: []?u64,
    remaining: usize,

    const empty: CreatedIds = .{ .names = &.{}, .ids = &.{}, .remaining = 0 };

    fn init(alloc: Allocator, n: usize) Allocator.Error!CreatedIds {
        const names = try alloc.alloc([]const u8, n);
        @memset(names, "");
        const ids = try alloc.alloc(?u64, n);
        @memset(ids, null);
        return .{ .names = names, .ids = ids, .remaining = n };
    }

    /// Record the id of entry `i`. Returns true when this resolved the last
    /// missing id.
    fn resolve(self: *CreatedIds, i: usize, id: u64) bool {
        if (self.ids[i] != null) return false;
        self.ids[i] = id;
        self.remaining -= 1;
        return self.remaining == 0;
    }

    /// `{"created":{"<name>":"0x…"|null},"closed":["0x…"],"dry_run":bool}`;
    /// unresolved ids are null.
    fn writeResult(
        self: *const CreatedIds,
        w: *std.Io.Writer,
        closed: []const u64,
        dry_run: bool,
    ) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("created");
        try s.beginObject();
        for (self.names, self.ids) |name, id_| {
            try s.objectField(name);
            if (id_) |id| try s.print("\"0x{x:0>16}\"", .{id}) else try s.write(null);
        }
        try s.endObject();
        try s.objectField("closed");
        try s.beginArray();
        for (closed) |id| try s.print("\"0x{x:0>16}\"", .{id});
        try s.endArray();
        try s.objectField("dry_run");
        try s.write(dry_run);
        try s.endObject();
    }
};

fn returnString(invocation: *gio.DBusMethodInvocation, s: [:0]const u8) void {
    const children = [_]*glib.Variant{glib.Variant.newString(s.ptr)};
    invocation.returnValue(glib.Variant.newTuple(&children, children.len));
}

fn returnError(
    alloc: Allocator,
    invocation: *gio.DBusMethodInvocation,
    comptime name: [:0]const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrintSentinel(alloc, fmt, args, 0) catch {
        invocation.returnDbusError(name, "out of memory formatting error message");
        return;
    };
    defer alloc.free(msg);
    invocation.returnDbusError(name, msg.ptr);
}

test "CreatedIds: resolves in any order and reports completion once" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ids: CreatedIds = try .init(arena.allocator(), 2);
    ids.names[0] = "a";
    ids.names[1] = "b";
    try testing.expect(!ids.resolve(1, 0x2));
    try testing.expect(!ids.resolve(1, 0x3)); // duplicate ignored
    try testing.expectEqual(1, ids.remaining);
    try testing.expect(ids.resolve(0, 0x1));
    try testing.expectEqual(0, ids.remaining);
    try testing.expectEqual(@as(?u64, 0x2), ids.ids[1]);
}

test "CreatedIds: result JSON with missing ids (timeout)" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var ids: CreatedIds = try .init(arena.allocator(), 2);
    ids.names[0] = "editor";
    ids.names[1] = "we\"ird";
    _ = ids.resolve(0, 0xdeadbeef);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try ids.writeResult(&aw.writer, &.{ 0x1, 0xffffffffffffffff }, false);
    try testing.expectEqualStrings(
        \\{"created":{"editor":"0x00000000deadbeef","we\"ird":null},"closed":["0x0000000000000001","0xffffffffffffffff"],"dry_run":false}
    , aw.written());
}

test "CreatedIds: empty result" {
    const testing = std.testing;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try CreatedIds.empty.writeResult(&aw.writer, &.{}, true);
    try testing.expectEqualStrings(
        \\{"created":{},"closed":[],"dry_run":true}
    , aw.written());
}
