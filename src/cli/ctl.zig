const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const global = @import("../global.zig");
const xdg = @import("../os/xdg.zig");
const homedir = @import("../os/homedir.zig");
const edit = @import("ctl/edit.zig");
const UndoStore = @import("ctl/UndoStore.zig");
const skill = @import("ctl/skill.zig");

/// The D-Bus client; only GTK builds can talk to a running Ghostty.
const Client = if (apprt.runtime == apprt.gtk)
    @import("../apprt/gtk/ipc/control.zig")
else
    void;

pub const Options = struct {
    /// Talk to the Ghostty instance with this class (application ID).
    class: ?[:0]const u8 = null,

    /// Pretty-print JSON output.
    pretty: bool = false,

    /// Validate only; change nothing.
    @"dry-run": bool = false,

    /// `layout apply`: close existing surfaces the spec doesn't place.
    @"allow-close": bool = false,

    /// `move`: the surface to move next to.
    to: ?[]const u8 = null,

    /// `move`: which side of the target surface.
    edge: ?edit.Edge = null,

    /// `to-tab`: the window to add the tab to.
    window: ?u32 = null,

    /// `to-tab`: put the tab in a new window.
    @"new-window": bool = false,

    /// `to-tab`: tab index (default: last).
    position: ?usize = null,

    /// `ratio`: the direction of the split to resize.
    layout: ?edit.Layout = null,

    /// `ratio`: the new share of the left/top side, in (0, 1).
    value: ?f64 = null,

    /// `skill install`: target agent.
    agent: ?skill.Agent = null,

    /// `skill install`: install root instead of the agent's skills dir.
    dest: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `+ctl` command reads and rearranges the windows, tabs and splits of a
/// running Ghostty instance through its `dev.tony.Ghostty.Control` D-Bus
/// interface. Running terminals are moved, never restarted.
///
/// Commands (run `ghostty +ctl <command> --help` for details):
///
///   * `layout get [--pretty]`: print the layout as JSON.
///
///   * `layout apply [FILE|-] [--dry-run] [--allow-close]`: rearrange
///     everything to match a layout spec (JSON, read from FILE or stdin).
///
///   * `layout undo [--dry-run]`: revert the last change made by `+ctl`.
///
///   * `focus [ID]`: focus a surface (select its tab, present its window).
///
///   * `move [SRC] --to=ID --edge=left|right|up|down`: move a surface next
///     to another one.
///
///   * `swap A [B]`: exchange two surfaces.
///
///   * `to-tab [SRC] [--window=WID|--new-window] [--position=N]`: move a
///     surface into a tab of its own.
///
///   * `ratio [ID] --layout=horizontal|vertical --value=R`: resize the
///     nearest enclosing split of that direction.
///
///   * `skill show|install`: print or install the agent skill describing
///     this command (for omp, Claude Code, Codex).
///
/// Surface IDs are hex strings such as `0x0123456789abcdef`, the value of
/// `$GHOSTTY_SURFACE_ID` in every Ghostty shell. Surface arguments shown as
/// optional default to `$GHOSTTY_SURFACE_ID`. Window IDs are the numeric
/// `id` fields of `layout get`.
///
/// Every command that changes the layout first saves the current layout to
/// an undo stack in `$XDG_STATE_HOME/ghostty/ctl/<class>/` (the last 20
/// changes are kept) and prints the ApplyLayout result:
/// `{"created":{"<name>":"0x…"|null},"closed":["0x…"],"dry_run":false}`.
///
/// On failure the reason (for example the server's validation error) is
/// printed to stderr and the exit code is non-zero; a rejected layout
/// changes nothing.
///
/// Only supported on GTK.
///
/// Flags:
///
///   * `--class=<class>`: Talk to the Ghostty instance with this class
///     (GTK application ID). Defaults to `com.mitchellh.ghostty` for release
///     builds and `com.mitchellh.ghostty-debug` for debug builds.
///
///   * `--pretty`: Pretty-print JSON output.
///
///   * `--dry-run`: Validate the resulting layout without changing anything.
pub fn run(alloc_gpa: Allocator) !u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    {
        var iter = try args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        while (iter.next()) |arg| try argv.append(alloc, try alloc.dupe(u8, arg));
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(global.io(), &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buf);
    const stderr = &stderr_writer.interface;

    defer stdout.flush() catch {};
    defer stderr.flush() catch {};
    return runArgs(alloc, argv.items, stdout, stderr);
}

const Command = enum {
    layout_get,
    layout_apply,
    layout_undo,
    focus,
    move,
    swap,
    to_tab,
    ratio,
    skill_show,
    skill_install,

    fn name(self: Command) []const u8 {
        return switch (self) {
            .layout_get => "layout get",
            .layout_apply => "layout apply",
            .layout_undo => "layout undo",
            .focus => "focus",
            .move => "move",
            .swap => "swap",
            .to_tab => "to-tab",
            .ratio => "ratio",
            .skill_show => "skill show",
            .skill_install => "skill install",
        };
    }

    /// Flags accepted besides `--class` and `--help`.
    fn flags(self: Command) []const []const u8 {
        return switch (self) {
            .layout_get => &.{"pretty"},
            .layout_apply => &.{ "pretty", "dry-run", "allow-close" },
            .layout_undo => &.{ "pretty", "dry-run" },
            .focus => &.{},
            .move => &.{ "pretty", "dry-run", "to", "edge" },
            .swap => &.{ "pretty", "dry-run" },
            .to_tab => &.{ "pretty", "dry-run", "window", "new-window", "position" },
            .ratio => &.{ "pretty", "dry-run", "layout", "value" },
            .skill_show => &.{},
            .skill_install => &.{ "agent", "dest" },
        };
    }

    fn maxPositionals(self: Command) usize {
        return switch (self) {
            .layout_get, .layout_undo, .skill_show, .skill_install => 0,
            .layout_apply, .focus, .move, .to_tab, .ratio => 1,
            .swap => 2,
        };
    }

    fn help(self: Command) []const u8 {
        return switch (self) {
            .layout_get => help_layout_get,
            .layout_apply => help_layout_apply,
            .layout_undo => help_layout_undo,
            .focus => help_focus,
            .move => help_move,
            .swap => help_swap,
            .to_tab => help_to_tab,
            .ratio => help_ratio,
            .skill_show => help_skill_show,
            .skill_install => help_skill_install,
        };
    }
};

// Help fragments start with a blank line and end without a newline, as do
// the texts they are appended to.

const common_flags =
    \\
    \\
    \\  * `--class=<class>`: Talk to the Ghostty instance with this class
    \\    (GTK application ID) instead of the default one.
;

const change_flags =
    \\
    \\
    \\  * `--dry-run`: Validate the resulting layout without changing anything
    \\    (and without saving an undo entry).
    \\
    \\  * `--pretty`: Pretty-print the JSON result.
;

const change_note =
    \\
    \\
    \\The current layout is saved to the undo stack first (see
    \\`ghostty +ctl layout undo`), then the result of ApplyLayout is printed:
    \\`{"created":{…},"closed":[…],"dry_run":false}`.
    \\
    \\Flags:
;

const help_layout =
    \\Usage: ghostty +ctl layout get|apply|undo [flags]
    \\
    \\  * `get`: print the layout as JSON.
    \\  * `apply`: rearrange everything to match a layout spec.
    \\  * `undo`: revert the last change made by `+ctl`.
    \\
    \\Run `ghostty +ctl layout <command> --help` for details.
;

const help_layout_get =
    \\Usage: ghostty +ctl layout get [--pretty]
    \\
    \\Print the layout of every window as JSON:
    \\
    \\  {"version":1,"focused_surface":"0x…","windows":[{"id":1,"active":true,
    \\   "quick_terminal":false,"title":"…","selected_tab":0,"tabs":[{"index":0,
    \\   "selected":true,"title":"…","zoomed":null,"tree":NODE}]}]}
    \\
    \\NODE is either a split, {"type":"split","layout":"horizontal"|"vertical",
    \\"ratio":0.5,"left":NODE,"right":NODE} ("horizontal" = left|right,
    \\"vertical" = top/bottom, ratio = share of the left/top child), or a
    \\surface, {"type":"surface","id":"0x…","pid":…,"fg_pid":…,"fg_comm":"…",
    \\"fg_cmdline":[…],"title":"…","cwd":"…","focused":false}.
    \\
    \\The output is itself a valid spec for `ghostty +ctl layout apply`.
    \\
    \\Flags:
    \\
    \\  * `--pretty`: Pretty-print the JSON.
++ common_flags;

const help_layout_apply =
    \\Usage: ghostty +ctl layout apply [FILE|-] [--dry-run] [--allow-close]
    \\
    \\Rearrange all windows, tabs and splits to match a layout spec read from
    \\FILE (or stdin when FILE is `-` or omitted). Running surfaces are moved,
    \\never restarted. The spec is fully validated before anything changes.
    \\
    \\  {"version":1,
    \\   "windows":[{"id":3,            // existing window; omit for a new one
    \\               "selected_tab":0,  // optional
    \\               "tabs":[{"zoomed":"0x…"|null,"tree":NODE}]}],
    \\   "focus":"0x…"|"name"}          // optional
    \\
    \\  NODE = {"type":"split","layout":"horizontal"|"vertical","ratio":0.5,
    \\          "left":NODE,"right":NODE}
    \\       | {"type":"surface","id":"0x…"}          // existing surface
    \\       | {"type":"surface","new":{"name":"n",   // spawn a new surface
    \\          "command":["argv",…]|"shell string","cwd":"/…","title":"…"}}
    \\
    \\Every existing surface (outside the quick terminal) must be placed
    \\exactly once unless `--allow-close` is given. Existing windows left out
    \\of the spec close once all their surfaces were moved elsewhere. The
    \\output of `ghostty +ctl layout get` is a valid spec.
++ change_note ++
    \\
    \\
    \\  * `--allow-close`: Close existing surfaces that the spec doesn't place
    \\    instead of rejecting the spec.
++ change_flags ++ common_flags;

const help_layout_undo =
    \\Usage: ghostty +ctl layout undo [--dry-run]
    \\
    \\Re-apply the layout saved before the last change made by `+ctl` and
    \\drop it from the undo stack. Surfaces that have exited since are
    \\skipped and windows that have closed are recreated. Surfaces created by
    \\the undone change are closed; if the undo would leave any other surface
    \\(for example one opened afterwards) without a place, it is refused.
    \\
    \\Flags:
++ change_flags ++ common_flags;

const help_focus =
    \\Usage: ghostty +ctl focus [ID]
    \\
    \\Focus surface ID (default: $GHOSTTY_SURFACE_ID): select its tab, focus
    \\its split and present its window.
    \\
    \\Flags:
++ common_flags;

const help_move =
    \\Usage: ghostty +ctl move [SRC] --to=ID --edge=left|right|up|down
    \\
    \\Move surface SRC (default: $GHOSTTY_SURFACE_ID) next to surface ID, on
    \\the given side of it, splitting ID's space in half. SRC may be in any
    \\tab or window; a tab or window it leaves empty closes.
++ change_note ++
    \\
    \\
    \\  * `--to=<id>`: The surface to move next to (required).
    \\
    \\  * `--edge=left|right|up|down`: The side of `--to` to put SRC on
    \\    (required).
++ change_flags ++ common_flags;

const help_swap =
    \\Usage: ghostty +ctl swap A [B]
    \\
    \\Exchange the positions of surfaces A and B, which may be in different
    \\tabs or windows. With a single ID, swap $GHOSTTY_SURFACE_ID with it.
++ change_note ++ change_flags ++ common_flags;

const help_to_tab =
    \\Usage: ghostty +ctl to-tab [SRC] [--window=WID|--new-window] [--position=N]
    \\
    \\Move surface SRC (default: $GHOSTTY_SURFACE_ID) into a tab of its own:
    \\in its current window, in window WID, or in a new window.
++ change_note ++
    \\
    \\
    \\  * `--window=<id>`: Add the tab to this window (its `id` in
    \\    `ghostty +ctl layout get`).
    \\
    \\  * `--new-window`: Put the tab in a new window.
    \\
    \\  * `--position=<n>`: Tab index to insert at (default: after the last tab).
++ change_flags ++ common_flags;

const help_ratio =
    \\Usage: ghostty +ctl ratio [ID] --layout=horizontal|vertical --value=R
    \\
    \\Set the ratio of the nearest split around surface ID (default:
    \\$GHOSTTY_SURFACE_ID) with the given layout: `horizontal` splits are
    \\left|right, `vertical` splits top/bottom. R is the share of the left/top
    \\side, strictly between 0 and 1.
++ change_note ++
    \\
    \\
    \\  * `--layout=horizontal|vertical`: Which split to resize (required).
    \\
    \\  * `--value=<ratio>`: The new ratio (required).
++ change_flags ++ common_flags;

const help_skill =
    \\Usage: ghostty +ctl skill show|install [flags]
    \\
    \\  * `show`: print the bundled agent skill (SKILL.md).
    \\  * `install`: install it into an agent's skills directory.
    \\
    \\Run `ghostty +ctl skill <command> --help` for details.
;

const help_skill_show =
    \\Usage: ghostty +ctl skill show
    \\
    \\Print the bundled agent skill (SKILL.md) that teaches coding agents how
    \\to inspect and rearrange Ghostty with `ghostty +ctl`, so an agent can
    \\read it without installing it.
;

const help_skill_install =
    \\Usage: ghostty +ctl skill install [--agent=claude|codex|all] [--dest=DIR]
    \\
    \\Install the bundled agent skill as `<root>/ghostty-ctl/SKILL.md` (plus
    \\`agents/openai.yaml`), replacing any previous copy, and print
    \\`{"installed":[{"agent":"claude","path":"…"}]}`. Does not need a
    \\running Ghostty.
    \\
    \\Flags:
    \\
    \\  * `--agent=claude|codex|all`: Target agent (default: claude). Roots:
    \\    `$CLAUDE_HOME/skills` (default `~/.claude/skills`, which omp also
    \\    reads) and `$CODEX_HOME/skills` (default `~/.codex/skills`).
    \\
    \\  * `--dest=<dir>`: Install root instead of the agent's skills
    \\    directory; with `--agent=all`, `<dir>/codex` and `<dir>/claude`.
;

/// A parsed command line.
const Invocation = struct {
    command: Command,
    opts: Options,
    positionals: []const []const u8,
};

const ParseResult = union(enum) {
    run: Invocation,
    /// Print this help text and exit 0.
    help: []const u8,
    /// A usage error was written to stderr.
    usage,
};

fn parseArgs(alloc: Allocator, argv: []const []const u8, stderr: *std.Io.Writer) !ParseResult {
    var opts: Options = .{};
    var seen: std.ArrayList([]const u8) = .empty;
    var positionals: std.ArrayList([]const u8) = .empty;
    var want_help = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            want_help = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const flag = if (eq) |e| body[0..e] else body;
            var value: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

            const known = inline for (@typeInfo(Options).@"struct".field_names) |field| {
                if (std.mem.eql(u8, field, flag)) {
                    const T = @FieldType(Options, field);
                    if (T == bool) {
                        @field(opts, field) = if (value) |v| parseBool(v) orelse {
                            try stderr.print("error: invalid value for --{s}: {s}\n", .{ flag, v });
                            return .usage;
                        } else true;
                    } else {
                        if (value == null) {
                            i += 1;
                            if (i >= argv.len) {
                                try stderr.print("error: --{s} requires a value\n", .{flag});
                                return .usage;
                            }
                            value = argv[i];
                        }
                        @field(opts, field) = parseValue(@typeInfo(T).optional.child, alloc, value.?) catch {
                            try stderr.print("error: invalid value for --{s}: {s}\n", .{ flag, value.? });
                            return .usage;
                        };
                    }
                    try seen.append(alloc, field);
                    break true;
                }
            } else false;

            if (!known) {
                try stderr.print("error: unknown flag --{s}\n", .{flag});
                return .usage;
            }
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            try stderr.print("error: unknown flag {s}\n", .{arg});
            return .usage;
        }
        try positionals.append(alloc, arg);
    }

    const pos = positionals.items;
    if (pos.len == 0) {
        if (want_help) return Action.help_error;
        try stderr.writeAll("error: missing command; see `ghostty +ctl --help`\n");
        return .usage;
    }

    var rest = pos[1..];
    const command: Command = if (std.mem.eql(u8, pos[0], "layout")) cmd: {
        if (rest.len == 0) {
            if (want_help) return .{ .help = help_layout };
            try stderr.writeAll("error: missing layout command (get, apply or undo)\n");
            return .usage;
        }
        const sub = rest[0];
        rest = rest[1..];
        if (std.mem.eql(u8, sub, "get")) break :cmd .layout_get;
        if (std.mem.eql(u8, sub, "apply")) break :cmd .layout_apply;
        if (std.mem.eql(u8, sub, "undo")) break :cmd .layout_undo;
        try stderr.print("error: unknown layout command: {s}\n", .{sub});
        return .usage;
    } else if (std.mem.eql(u8, pos[0], "skill")) cmd: {
        if (rest.len == 0) {
            if (want_help) return .{ .help = help_skill };
            try stderr.writeAll("error: missing skill command (show or install)\n");
            return .usage;
        }
        const sub = rest[0];
        rest = rest[1..];
        if (std.mem.eql(u8, sub, "show")) break :cmd .skill_show;
        if (std.mem.eql(u8, sub, "install")) break :cmd .skill_install;
        try stderr.print("error: unknown skill command: {s}\n", .{sub});
        return .usage;
    } else if (std.mem.eql(u8, pos[0], "focus"))
        .focus
    else if (std.mem.eql(u8, pos[0], "move"))
        .move
    else if (std.mem.eql(u8, pos[0], "swap"))
        .swap
    else if (std.mem.eql(u8, pos[0], "to-tab"))
        .to_tab
    else if (std.mem.eql(u8, pos[0], "ratio"))
        .ratio
    else {
        try stderr.print("error: unknown command: {s}; see `ghostty +ctl --help`\n", .{pos[0]});
        return .usage;
    };

    if (want_help) return .{ .help = command.help() };

    for (seen.items) |flag| {
        if (std.mem.eql(u8, flag, "class")) continue;
        for (command.flags()) |allowed| {
            if (std.mem.eql(u8, flag, allowed)) break;
        } else {
            try stderr.print("error: --{s} is not valid for `+ctl {s}`\n", .{ flag, command.name() });
            return .usage;
        }
    }

    if (rest.len > command.maxPositionals()) {
        try stderr.print("error: too many arguments for `+ctl {s}`\n", .{command.name()});
        return .usage;
    }

    const missing: ?[]const u8 = switch (command) {
        .move => if (opts.to == null) "--to" else if (opts.edge == null) "--edge" else null,
        .swap => if (rest.len == 0) "a surface ID" else null,
        .ratio => if (opts.layout == null) "--layout" else if (opts.value == null) "--value" else null,
        else => null,
    };
    if (missing) |m| {
        try stderr.print("error: `+ctl {s}` requires {s}\n", .{ command.name(), m });
        return .usage;
    }
    if (command == .to_tab and opts.window != null and opts.@"new-window") {
        try stderr.writeAll("error: --window and --new-window are mutually exclusive\n");
        return .usage;
    }

    return .{ .run = .{ .command = command, .opts = opts, .positionals = rest } };
}

fn parseBool(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

fn parseValue(comptime T: type, alloc: Allocator, v: []const u8) !T {
    return switch (@typeInfo(T)) {
        .@"enum" => std.meta.stringToEnum(T, v) orelse error.InvalidValue,
        .int => try std.fmt.parseUnsigned(T, v, 0),
        .float => try std.fmt.parseFloat(T, v),
        .pointer => if (T == [:0]const u8) try alloc.dupeSentinel(u8, v, 0) else try alloc.dupe(u8, v),
        else => @compileError("unsupported +ctl option type"),
    };
}

fn runArgs(
    alloc: Allocator,
    argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const inv = switch (try parseArgs(alloc, argv, stderr)) {
        .run => |inv| inv,
        .help => |text| {
            try stdout.print("{s}\n", .{text});
            return 0;
        },
        .usage => return 2,
    };

    // Local commands: no running Ghostty needed.
    switch (inv.command) {
        .skill_show => {
            try stdout.writeAll(skill.skill_md);
            return 0;
        },
        .skill_install => return skillInstall(alloc, inv.opts, stdout, stderr),
        else => {},
    }

    if (comptime Client == void) {
        try stderr.writeAll("+ctl is only supported on GTK.\n");
        return 1;
    } else {
        var client = Client.init(
            alloc,
            if (inv.opts.class) |class| .{ .class = class } else .detect,
        ) catch |err| return ipcFailure(stderr, err);
        defer client.deinit(alloc);

        var ctx: Ctx = .{
            .alloc = alloc,
            .inv = inv,
            .client = &client,
            .stdout = stdout,
            .stderr = stderr,
        };
        return ctx.exec() catch |err| switch (err) {
            error.IPCFailed, error.InvalidLayout => 1,
            else => {
                try stderr.print("error: {t}\n", .{err});
                return 1;
            },
        };
    }
}

fn skillInstall(
    alloc: Allocator,
    opts: Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const io = global.io();
    var env = try global.environMap();
    defer env.deinit();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try homedir.home(io, &env, &home_buf)) orelse {
        try stderr.writeAll("error: unable to determine the home directory\n");
        return 1;
    };
    const rs = try skill.roots(alloc, &env, home, opts.agent orelse .claude, opts.dest);
    const installed = skill.install(io, alloc, rs) catch |err| {
        try stderr.print("error: unable to install the skill: {t}\n", .{err});
        return 1;
    };
    try std.json.Stringify.value(.{ .installed = installed }, .{}, stdout);
    try stdout.writeAll("\n");
    return 0;
}

/// Errors from the client have already been reported on stderr.
fn ipcFailure(stderr: *std.Io.Writer, err: anyerror) !u8 {
    switch (err) {
        error.IPCFailed, error.InvalidLayout => {},
        else => try stderr.print("error: {t}\n", .{err}),
    }
    return 1;
}

const Ctx = struct {
    alloc: Allocator,
    inv: Invocation,
    client: if (Client == void) void else *Client,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    fn exec(self: *Ctx) !u8 {
        const pos = self.inv.positionals;
        const opts = self.inv.opts;
        switch (self.inv.command) {
            .layout_get => {
                const layout = try self.client.getLayout(self.alloc);
                try self.printJson(layout);
                return 0;
            },

            .layout_apply => {
                const path = if (pos.len > 0) pos[0] else "-";
                const spec_json = self.readInput(path) catch |err| {
                    try self.stderr.print("error: unable to read {s}: {t}\n", .{ path, err });
                    return 1;
                };
                return self.applyWithUndo(spec_json, null, opts.@"allow-close");
            },

            .layout_undo => return self.undo(),

            .focus => {
                const id = try self.surfaceArg(if (pos.len > 0) pos[0] else null) orelse return 1;
                try self.client.focus(id);
                return 0;
            },

            .move, .swap, .to_tab, .ratio => return self.editLayout(),
            // Handled in runArgs before connecting.
            .skill_show, .skill_install => unreachable,
        }
    }

    /// GetLayout → pure JSON edit → ApplyLayout.
    fn editLayout(self: *Ctx) !u8 {
        const pos = self.inv.positionals;
        const opts = self.inv.opts;

        // Resolve every id before talking to the server.
        const src = try self.surfaceArg(switch (self.inv.command) {
            .swap => if (pos.len == 2) pos[0] else null,
            else => if (pos.len > 0) pos[0] else null,
        }) orelse return 1;
        const other: u64 = switch (self.inv.command) {
            .move => try self.surfaceArg(opts.to.?) orelse return 1,
            .swap => try self.surfaceArg(pos[pos.len - 1]) orelse return 1,
            else => 0,
        };

        const before = try self.client.getLayout(self.alloc);
        var doc = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, before, .{});
        edit.toSpec(self.alloc, &doc) catch |err| return self.editFailure(err);
        const edited = switch (self.inv.command) {
            .move => edit.move(self.alloc, &doc, src, other, opts.edge.?),
            .swap => edit.swap(self.alloc, &doc, src, other),
            .to_tab => edit.toTab(
                self.alloc,
                &doc,
                src,
                if (opts.window) |w|
                    .{ .window = w }
                else if (opts.@"new-window")
                    .new_window
                else
                    .current,
                opts.position,
            ),
            .ratio => edit.setRatio(self.alloc, &doc, src, opts.layout.?, opts.value.?),
            else => unreachable,
        };
        edited catch |err| return self.editFailure(err);

        const spec_json = try std.json.Stringify.valueAlloc(self.alloc, doc, .{});
        return self.applyWithUndo(spec_json, before, false);
    }

    fn editFailure(self: *Ctx, err: edit.Error) !u8 {
        const msg = switch (err) {
            error.OutOfMemory => return err,
            error.MalformedLayout => "the server returned an unexpected layout document",
            error.SurfaceNotFound => "surface not found (surfaces in the quick terminal can't be moved)",
            error.WindowNotFound => "window not found (see `ghostty +ctl layout get`)",
            error.SameSurface => "the two surfaces must be different",
            error.NoSplit => "no enclosing split with that layout",
            error.InvalidRatio => "the ratio must be strictly between 0 and 1",
            error.NothingToRestore => "none of the saved surfaces exist anymore",
        };
        try self.stderr.print("error: {s}\n", .{msg});
        return 1;
    }

    /// Apply a spec. Unless this is a dry run, the current layout (`before`,
    /// or freshly fetched) is pushed to the undo stack first and the entry
    /// records the surfaces the apply created.
    fn applyWithUndo(self: *Ctx, spec_json: []const u8, before_: ?[]const u8, allow_close: bool) !u8 {
        const dry_run = self.inv.opts.@"dry-run";
        const spec_z = try self.alloc.dupeSentinel(u8, spec_json, 0);
        const options = try optionsJson(self.alloc, allow_close, dry_run);

        if (dry_run) {
            const result = try self.client.applyLayout(self.alloc, spec_z, options);
            try self.printJson(result);
            return 0;
        }

        var store = try self.openStore();
        defer store.close();
        const before = before_ orelse try self.client.getLayout(self.alloc);
        const entry = try store.push(self.alloc, before);

        const result = self.client.applyLayout(self.alloc, spec_z, options) catch |err| {
            // A rejected layout changed nothing: forget the undo entry.
            if (err == error.InvalidLayout) try store.remove(&entry);
            return err;
        };

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, result, .{});
        const created = edit.createdIds(self.alloc, parsed) catch &.{};
        if (created.len > 0) try store.setCreated(self.alloc, &entry, before, created);

        try self.printJson(result);
        return 0;
    }

    fn undo(self: *Ctx) !u8 {
        const dry_run = self.inv.opts.@"dry-run";
        var store = try self.openStore();
        defer store.close();
        var entry = try store.latest(self.alloc) orelse {
            try self.stderr.writeAll("error: nothing to undo\n");
            return 1;
        };

        const current_json = try self.client.getLayout(self.alloc);
        var current = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, current_json, .{});
        const plan = edit.planUndo(self.alloc, &current, &entry.layout, entry.created) catch |err|
            return self.editFailure(err);

        if (plan.refused.len > 0) {
            try self.stderr.writeAll("error: refusing to undo: these surfaces did not exist " ++
                "when the layout was saved and would be closed:");
            for (plan.refused) |id| try self.stderr.print(" 0x{x:0>16}", .{id});
            try self.stderr.writeAll("\nMove or close them first, or apply a layout explicitly.\n");
            return 1;
        }

        const spec_json = try std.json.Stringify.valueAlloc(self.alloc, plan.spec.*, .{});
        const result = try self.client.applyLayout(
            self.alloc,
            try self.alloc.dupeSentinel(u8, spec_json, 0),
            try optionsJson(self.alloc, plan.allowClose(), dry_run),
        );
        if (!dry_run) try store.remove(&entry.name);
        try self.printJson(result);
        return 0;
    }

    fn openStore(self: *Ctx) !UndoStore {
        var env = try global.environMap();
        defer env.deinit();
        const base = try xdg.state(global.io(), self.alloc, &env, .{ .subdir = "ghostty/ctl" });
        const path = try std.fs.path.join(self.alloc, &.{ base, self.client.endpoint.bus_name });
        return UndoStore.open(global.io(), path) catch |err| {
            try self.stderr.print("error: unable to open undo stack {s}: {t}\n", .{ path, err });
            return error.IPCFailed;
        };
    }

    /// Parse a surface id argument, defaulting to $GHOSTTY_SURFACE_ID. Null
    /// after reporting an error.
    fn surfaceArg(self: *Ctx, arg: ?[]const u8) !?u64 {
        if (arg) |a| return edit.parseId(a) catch {
            try self.stderr.print("error: invalid surface ID: {s}\n", .{a});
            return null;
        };
        var env = try global.environMap();
        defer env.deinit();
        const v = env.get("GHOSTTY_SURFACE_ID") orelse {
            try self.stderr.writeAll("error: no surface ID given and $GHOSTTY_SURFACE_ID is not set\n");
            return null;
        };
        return edit.parseId(v) catch {
            try self.stderr.print("error: invalid $GHOSTTY_SURFACE_ID: {s}\n", .{v});
            return null;
        };
    }

    fn readInput(self: *Ctx, path: []const u8) ![]u8 {
        const io = global.io();
        if (std.mem.eql(u8, path, "-")) {
            var buf: [4096]u8 = undefined;
            var reader = std.Io.File.stdin().readerStreaming(io, &buf);
            return reader.interface.allocRemaining(self.alloc, .limited(64 * 1024 * 1024));
        }
        return std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(64 * 1024 * 1024));
    }

    fn printJson(self: *Ctx, text: []const u8) !void {
        if (self.inv.opts.pretty) {
            const v = try std.json.parseFromSliceLeaky(std.json.Value, self.alloc, text, .{});
            try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, self.stdout);
        } else {
            try self.stdout.writeAll(text);
        }
        try self.stdout.writeByte('\n');
    }
};

fn optionsJson(alloc: Allocator, allow_close: bool, dry_run: bool) Allocator.Error![:0]u8 {
    return std.fmt.allocPrintSentinel(
        alloc,
        "{{\"allow_close\":{},\"dry_run\":{}}}",
        .{ allow_close, dry_run },
        0,
    );
}

test {
    _ = edit;
    _ = UndoStore;
    _ = skill;
}

fn testParse(alloc: Allocator, line: []const []const u8) !ParseResult {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    return parseArgs(alloc, line, &discard.writer);
}

test "ctl: parse commands" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const r = (try testParse(alloc, &.{ "move", "0x1", "--to", "0x2", "--edge=up", "--class=a.b" })).run;
        try testing.expectEqual(Command.move, r.command);
        try testing.expectEqualStrings("0x2", r.opts.to.?);
        try testing.expectEqual(edit.Edge.up, r.opts.edge.?);
        try testing.expectEqualStrings("a.b", r.opts.class.?);
        try testing.expectEqual(@as(usize, 1), r.positionals.len);
    }
    {
        const r = (try testParse(alloc, &.{ "layout", "apply", "-", "--dry-run", "--allow-close" })).run;
        try testing.expectEqual(Command.layout_apply, r.command);
        try testing.expect(r.opts.@"dry-run" and r.opts.@"allow-close");
        try testing.expectEqualStrings("-", r.positionals[0]);
    }
    {
        const r = (try testParse(alloc, &.{ "ratio", "--layout=vertical", "--value", "0.3" })).run;
        try testing.expectEqual(edit.Layout.vertical, r.opts.layout.?);
        try testing.expectEqual(@as(f64, 0.3), r.opts.value.?);
    }
    {
        const r = (try testParse(alloc, &.{ "to-tab", "--window=3", "--position=0" })).run;
        try testing.expectEqual(@as(u32, 3), r.opts.window.?);
        try testing.expectEqual(@as(usize, 0), r.opts.position.?);
    }
    {
        const r = (try testParse(alloc, &.{ "skill", "install", "--agent=all", "--dest", "/d" })).run;
        try testing.expectEqual(Command.skill_install, r.command);
        try testing.expectEqual(skill.Agent.all, r.opts.agent.?);
        try testing.expectEqualStrings("/d", r.opts.dest.?);
    }
    try testing.expect((try testParse(alloc, &.{ "skill", "show", "--agent=all" })) == .usage);
    try testing.expect((try testParse(alloc, &.{ "focus", "--dest=/d" })) == .usage);
}

test "ctl: parse help and usage errors" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(Action.help_error, testParse(alloc, &.{"--help"}));
    try testing.expectEqualStrings(help_move, (try testParse(alloc, &.{ "move", "-h" })).help);
    try testing.expectEqualStrings(help_layout, (try testParse(alloc, &.{ "layout", "--help" })).help);
    try testing.expectEqualStrings(help_layout_undo, (try testParse(alloc, &.{ "--help", "layout", "undo" })).help);

    const usage = [_][]const []const u8{
        &.{},
        &.{"bogus"},
        &.{ "layout", "nope" },
        &.{ "move", "--to=0x1" }, // missing --edge
        &.{ "move", "--to=0x1", "--edge=sideways" },
        &.{ "swap", "--edge=up", "0x1" }, // flag not valid here
        &.{ "swap", "1", "2", "3" },
        &.{ "focus", "--frobnicate" },
        &.{ "to-tab", "--window=1", "--new-window" },
        &.{ "ratio", "--layout=vertical" },
        &.{ "layout", "get", "--to" },
    };
    for (usage) |line| try testing.expect(try testParse(alloc, line) == .usage);
}
