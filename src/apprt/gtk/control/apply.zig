//! Applies a desired-layout spec to the live GTK application.
//! CONTRACT SCAFFOLD: owned by the tree slice, which replaces the body.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Application = @import("../class/application.zig").Application;
const Surface = @import("../class/surface.zig").Surface;
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
    closed: []const u64,
};

/// Validate `s` against the live application, then (unless opts.dry_run)
/// rearrange every window/tab/split to match it. Running surfaces are moved,
/// never restarted. On error.InvalidLayout nothing was changed and a
/// human-readable reason was written to `diag`.
pub fn apply(
    app: *Application,
    arena: Allocator,
    s: spec.Spec,
    opts: spec.Options,
    diag: *std.Io.Writer,
) Error!Result {
    _ = app;
    _ = arena;
    _ = s;
    _ = opts;
    try diag.writeAll("apply: not implemented");
    return error.InvalidLayout;
}
