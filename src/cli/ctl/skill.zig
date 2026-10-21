//! `ghostty +ctl skill show|install`: the agent skill describing `+ctl`,
//! bundled into the binary. Same layout and semantics as the `skill`
//! subcommand of Tony's `agent-*` tools: `<root>/ghostty-ctl/SKILL.md` and
//! `<root>/ghostty-ctl/agents/openai.yaml`, replacing any previous copy.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const name = "ghostty-ctl";
pub const skill_md = @embedFile("skill/SKILL.md");
pub const openai_yaml = @embedFile("skill/openai.yaml");

pub const Agent = enum { claude, codex, all };

pub const Root = struct {
    agent: []const u8,
    /// The skills directory; the skill goes into `<path>/ghostty-ctl`.
    path: []const u8,
};

pub const Installed = struct {
    agent: []const u8,
    path: []const u8,
};

/// Where to install for `agent`. `dest` overrides the agents' skills
/// directories (`all` then installs into `dest/codex` and `dest/claude`).
/// Defaults: `$CLAUDE_HOME/skills` (else `~/.claude/skills`) and
/// `$CODEX_HOME/skills` (else `~/.codex/skills`).
pub fn roots(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    home: []const u8,
    agent: Agent,
    dest: ?[]const u8,
) Allocator.Error![]const Root {
    const pick = struct {
        fn dir(
            a: Allocator,
            e: *const std.process.Environ.Map,
            h: []const u8,
            var_name: []const u8,
            dot: []const u8,
        ) Allocator.Error![]const u8 {
            if (e.get(var_name)) |v| if (v.len > 0) return std.fs.path.join(a, &.{ v, "skills" });
            return std.fs.path.join(a, &.{ h, dot, "skills" });
        }
    }.dir;

    if (dest) |d| return switch (agent) {
        .claude => try alloc.dupe(Root, &.{.{ .agent = "claude", .path = d }}),
        .codex => try alloc.dupe(Root, &.{.{ .agent = "codex", .path = d }}),
        .all => try alloc.dupe(Root, &.{
            .{ .agent = "codex", .path = try std.fs.path.join(alloc, &.{ d, "codex" }) },
            .{ .agent = "claude", .path = try std.fs.path.join(alloc, &.{ d, "claude" }) },
        }),
    };
    const claude: Root = .{ .agent = "claude", .path = try pick(alloc, env, home, "CLAUDE_HOME", ".claude") };
    const codex: Root = .{ .agent = "codex", .path = try pick(alloc, env, home, "CODEX_HOME", ".codex") };
    return switch (agent) {
        .claude => try alloc.dupe(Root, &.{claude}),
        .codex => try alloc.dupe(Root, &.{codex}),
        .all => try alloc.dupe(Root, &.{ codex, claude }),
    };
}

/// Write the skill into every root, replacing an existing copy.
pub fn install(io: std.Io, alloc: Allocator, rs: []const Root) ![]const Installed {
    const out = try alloc.alloc(Installed, rs.len);
    const cwd = std.Io.Dir.cwd();
    for (rs, out) |r, *o| {
        const path = try std.fs.path.join(alloc, &.{ r.path, name });
        try cwd.deleteTree(io, path);
        try cwd.createDirPath(io, try std.fs.path.join(alloc, &.{ path, "agents" }));
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(alloc, &.{ path, "SKILL.md" }),
            .data = skill_md,
        });
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(alloc, &.{ path, "agents", "openai.yaml" }),
            .data = openai_yaml,
        });
        o.* = .{ .agent = r.agent, .path = path };
    }
    return out;
}

const testing = std.testing;

test "skill: roots honour CLAUDE_HOME/CODEX_HOME, home fallback and dest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env: std.process.Environ.Map = .init(a);
    try env.put("CODEX_HOME", "/cx");

    const all = try roots(a, &env, "/home/u", .all, null);
    try testing.expectEqual(2, all.len);
    try testing.expectEqualStrings("codex", all[0].agent);
    try testing.expectEqualStrings("/cx/skills", all[0].path);
    try testing.expectEqualStrings("claude", all[1].agent);
    try testing.expectEqualStrings("/home/u/.claude/skills", all[1].path);

    const one = try roots(a, &env, "/home/u", .claude, "/d");
    try testing.expectEqual(1, one.len);
    try testing.expectEqualStrings("/d", one[0].path);

    const both = try roots(a, &env, "/home/u", .all, "/d");
    try testing.expectEqualStrings("/d/codex", both[0].path);
    try testing.expectEqualStrings("/d/claude", both[1].path);
}

test "skill: install writes both files and replaces a previous copy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);

    // A stale file from an older version must disappear.
    const stale = try std.fs.path.join(a, &.{ base, name, "old.txt" });
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ base, name }));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = stale, .data = "x" });

    const done = try install(io, a, &.{.{ .agent = "claude", .path = base }});
    try testing.expectEqual(1, done.len);

    const md = try tmp.dir.readFileAlloc(io, name ++ "/SKILL.md", a, .unlimited);
    try testing.expectEqualStrings(skill_md, md);
    const yaml = try tmp.dir.readFileAlloc(io, name ++ "/agents/openai.yaml", a, .unlimited);
    try testing.expectEqualStrings(openai_yaml, yaml);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, name ++ "/old.txt", .{}));
}
