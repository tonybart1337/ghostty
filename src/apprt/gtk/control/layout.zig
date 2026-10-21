//! GetLayout JSON writer and ApplyLayout spec/options parser.
//! CONTRACT SCAFFOLD: owned by the snapshot slice, which replaces the bodies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Application = @import("../class/application.zig").Application;
const spec = @import("spec.zig");

pub const ParseError = error{ InvalidSpec, OutOfMemory, WriteFailed };

/// Write the GetLayout JSON document (see spec.zig for the shared node shape)
/// for every window of `app`.
pub fn write(app: *Application, alloc: Allocator, w: *std.Io.Writer) !void {
    _ = app;
    _ = alloc;
    try w.writeAll("{\"version\":1,\"windows\":[]}");
}

/// Parse an ApplyLayout spec. Everything is allocated in `arena`. On
/// error.InvalidSpec a human-readable reason is written to `diag`.
pub fn parseSpec(arena: Allocator, json: []const u8, diag: *std.Io.Writer) ParseError!spec.Spec {
    _ = arena;
    _ = json;
    try diag.writeAll("parseSpec: not implemented");
    return error.InvalidSpec;
}

/// Parse ApplyLayout options: {"allow_close":bool,"dry_run":bool}; "" = defaults.
pub fn parseOptions(arena: Allocator, json: []const u8, diag: *std.Io.Writer) ParseError!spec.Options {
    _ = arena;
    _ = json;
    _ = diag;
    return .{};
}
