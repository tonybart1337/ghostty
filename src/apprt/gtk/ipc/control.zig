//! Client for the `dev.tony.Ghostty.Control` D-Bus interface exported by a
//! running Ghostty (GTK) on its GApplication object path. Used by
//! `ghostty +ctl`.
//!
//! Equivalent `gdbus` calls (release build):
//!
//! ```sh
//! gdbus call --session --dest com.mitchellh.ghostty \
//!   --object-path /com/mitchellh/ghostty \
//!   --method dev.tony.Ghostty.Control.GetLayout
//! gdbus call … --method dev.tony.Ghostty.Control.ApplyLayout '<spec json>' '{"dry_run":true}'
//! gdbus call … --method dev.tony.Ghostty.Control.Focus 0x0123456789abcdef
//! ```
const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const global = @import("../../../global.zig");
const DBus = @import("DBus.zig");

pub const interface = "dev.tony.Ghostty.Control";

/// D-Bus error name the server uses for spec validation failures.
pub const invalid_layout_error = interface ++ ".Error.InvalidLayout";

/// Reply timeout. ApplyLayout waits up to 5 s for new surfaces to get ids,
/// so leave generous headroom.
const timeout_ms = 30_000;

pub const Error = Allocator.Error || std.Io.Writer.Error || error{
    /// Transport or unexpected remote failure; the reason was written to
    /// stderr.
    IPCFailed,
    /// The server rejected the layout (`.Error.InvalidLayout`); the reason
    /// was written to stderr and nothing was changed.
    InvalidLayout,
};

endpoint: DBus.Endpoint,
dbus: *gio.DBusConnection,

pub fn init(alloc: Allocator, target: apprt.ipc.Target) Error!Client {
    const endpoint: DBus.Endpoint = try .init(alloc, target);
    errdefer endpoint.deinit(alloc);
    return .{
        .endpoint = endpoint,
        .dbus = try DBus.connectSession(),
    };
}

pub fn deinit(self: *Client, alloc: Allocator) void {
    self.dbus.unref();
    self.endpoint.deinit(alloc);
}

/// `GetLayout() -> (s)`. Caller owns the returned JSON.
pub fn getLayout(self: *Client, alloc: Allocator) Error![]u8 {
    return self.callString(alloc, "GetLayout", null);
}

/// `ApplyLayout(s spec, s options) -> (s)`. Caller owns the returned JSON.
pub fn applyLayout(
    self: *Client,
    alloc: Allocator,
    spec_json: [:0]const u8,
    options_json: [:0]const u8,
) Error![]u8 {
    const children = [_]*glib.Variant{
        glib.Variant.newString(spec_json.ptr),
        glib.Variant.newString(options_json.ptr),
    };
    return self.callString(alloc, "ApplyLayout", glib.Variant.newTuple(&children, children.len));
}

/// `Focus(t surface) -> ()`.
pub fn focus(self: *Client, surface_id: u64) Error!void {
    const children = [_]*glib.Variant{glib.Variant.newUint64(surface_id)};
    const reply = try self.call("Focus", glib.Variant.newTuple(&children, children.len), "()");
    reply.unref();
}

/// Call a method returning a single string. `params` is floating and
/// consumed.
fn callString(
    self: *Client,
    alloc: Allocator,
    method: [:0]const u8,
    params: ?*glib.Variant,
) Error![]u8 {
    const reply = try self.call(method, params, "(s)");
    defer reply.unref();
    const child = reply.getChildValue(0);
    defer child.unref();
    var len: usize = 0;
    const str = child.getString(&len);
    return try alloc.dupe(u8, str[0..len]);
}

fn call(
    self: *Client,
    method: [:0]const u8,
    params: ?*glib.Variant,
    reply_type: [:0]const u8,
) Error!*glib.Variant {
    const vt = glib.VariantType.new(reply_type.ptr);
    defer vt.free();

    var err_: ?*glib.Error = null;
    defer if (err_) |err| err.free();

    const reply_ = self.dbus.callSync(
        self.endpoint.bus_name,
        self.endpoint.object_path,
        interface,
        method,
        params,
        vt,
        .{},
        timeout_ms,
        null,
        &err_,
    );

    if (err_) |err| return reportError(err);
    return reply_ orelse {
        try printErr("D-Bus call {s} returned no reply\n", .{method});
        return error.IPCFailed;
    };
}

fn reportError(err: *glib.Error) Error {
    const name_ = gio.DBusError.getRemoteError(err);
    defer if (name_) |n| glib.free(n);
    _ = gio.DBusError.stripRemoteError(err);
    const msg = std.mem.span(err.f_message orelse "(unknown)");

    if (name_) |n| {
        const name = std.mem.span(n);
        if (std.mem.eql(u8, name, invalid_layout_error)) {
            try printErr("invalid layout: {s}\n", .{msg});
            return error.InvalidLayout;
        }
        try printErr("D-Bus error {s}: {s}\n", .{ name, msg });
        return error.IPCFailed;
    }

    try printErr("D-Bus call failed: {s}\n", .{msg});
    return error.IPCFailed;
}

fn printErr(comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    var buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;
    try stderr.print(fmt, args);
    try stderr.flush();
}
