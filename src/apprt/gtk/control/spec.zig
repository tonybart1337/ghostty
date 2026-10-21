//! Desired-layout specification for the `dev.tony.Ghostty.Control` D-Bus
//! interface's `ApplyLayout` method. Pure data: no GTK imports, so it can be
//! parsed and validated in unit tests.
//!
//! JSON form (version 1), produced/consumed by `ghostty +ctl`:
//!
//!   {"version":1,
//!    "windows":[{"id":3,              // existing window id from GetLayout; omit for a new window
//!                "selected_tab":0,    // optional
//!                "tabs":[{"zoomed":"0x…"|null, "tree":NODE}]}],
//!    "focus":"0x…" | "name"}          // optional: surface id or a `new` leaf's name
//!
//!   NODE = {"type":"split","layout":"horizontal"|"vertical","ratio":0.5,"left":NODE,"right":NODE}
//!        | {"type":"surface","id":"0x…"}                       // existing surface
//!        | {"type":"surface","new":{"name":"n","command":["argv",…]|"shell string",
//!                                   "cwd":"/…","title":"…"}}    // spawn a new surface
//!
//! Surface ids are hex strings ("0x%016x", same as GHOSTTY_SURFACE_ID) because
//! JSON numbers lose precision above 2^53. "horizontal" means left|right
//! children, "vertical" means top/bottom; ratio is the left/top share in (0,1).
//! Fields not listed above are ignored, so a GetLayout result (which carries
//! extra per-surface info) is itself a valid spec.

pub const version: u32 = 1;

pub const Spec = struct {
    windows: []const Window,
    focus: ?Ref = null,
};

pub const Window = struct {
    /// Existing window id (`gtk.ApplicationWindow.getId()`); null = new window.
    id: ?c_uint = null,
    selected_tab: ?usize = null,
    /// Non-empty.
    tabs: []const Tab,
};

pub const Tab = struct {
    zoomed: ?Ref = null,
    root: *const Node,
};

pub const Node = union(enum) {
    split: Split,
    surface: Leaf,
};

pub const Layout = enum { horizontal, vertical };

pub const Split = struct {
    layout: Layout,
    /// Share of the left/top child, clamped to (0, 1) by the parser.
    ratio: f16 = 0.5,
    left: *const Node,
    right: *const Node,
};

pub const Leaf = union(enum) {
    existing: u64,
    new: New,
};

/// A reference to a leaf: an existing surface id or a `new` leaf's name.
pub const Ref = union(enum) {
    id: u64,
    name: []const u8,
};

pub const New = struct {
    /// Unique among `new` leaves in the spec; reported back with the created id.
    name: []const u8,
    command: ?Command = null,
    cwd: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,
};

pub const Command = union(enum) {
    argv: []const [:0]const u8,
    shell: [:0]const u8,
};

pub const Options = struct {
    /// Existing surfaces missing from the spec are closed instead of being
    /// rejected with error.UnplacedSurface.
    allow_close: bool = false,
    /// Validate only; change nothing.
    dry_run: bool = false,
};
