//! Parse cost on large declarations, measured through shakedown:
//! `zig build bench`, or `parse [--smoke] [--row PREFIX]` from `zig-out/bench`.
//!
//! - wide: a command of 256 options of every kind, given 32 of them;
//! - deep: eight subcommands nested, each with its own options;
//! - lists: one list option given a thousand values;
//! - errors: an unknown option among 256, with the nearest suggested;
//! - small: a program's ordinary command line, and its help page;
//! - custom: an address read by its own type, beside the same text unread;
//! - relations: a command line checked against requires, a required group
//!   and implies, beside the same declaration without them;
//! - complete: a completion request answered by a completer;
//! - man: the manual page of the small program's subcommand.
const std = @import("std");
const ensign = @import("ensign");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

const Level = enum { low, middle, high };

/// 256 options cycling through integers, flags, enums, text and lists.
const Wide = blk: {
    @setEvalBranchQuota(1_000_000);
    const n = 256;
    var names: [n][:0]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    const kinds = [_]type{ u32, bool, Level, []const u8, []const []const u8 };
    const defaults = .{ @as(u32, 0), false, Level.low, @as([]const u8, ""), @as([]const []const u8, &.{}) };
    for (0..n) |i| {
        names[i] = std.fmt.comptimePrint("option-{d}", .{i});
        types[i] = kinds[i % kinds.len];
        attrs[i] = .{ .default_value_ptr = @ptrCast(&defaults[i % kinds.len]) }; // safe: each default has its field's type, as std's EnumFieldStruct points to one
    }
    break :blk @Struct(.auto, null, &names, &types, &attrs);
};

/// A command `depth` levels above its last subcommand.
fn Deep(comptime depth: usize) type {
    if (depth == 0) return struct { flag: bool = false, value: u32 = 0, name: []const u8 = "" };
    const Next = Deep(depth - 1);
    const names = [_][:0]const u8{"next"};
    const Sub = @Union(.auto, enum { next }, &names, &.{Next}, &@splat(.{}));
    return struct { flag: bool = false, value: u32 = 0, name: []const u8 = "", command: ?Sub = null };
}

const Small = struct {
    verbose: u8 = 0,
    command: union(enum) {
        build: struct {
            release: bool = false,
            jobs: u16 = 0,
            target: ?[]const u8 = null,
            files: []const []const u8 = &.{},
            pub const spec: ensign.Spec(@This()) = .{ .options = .{
                .release = .{ .short = 'r', .help = "Optimize for speed" },
                .jobs = .{ .short = 'j', .help = "Parallel jobs" },
                .files = .{ .positional = true, .hint = .file },
            } };
        },
    },
    pub const spec: ensign.Spec(@This()) = .{ .name = "small", .about = "A program's ordinary command line", .options = .{
        .verbose = .{ .short = 'v', .count = true, .global = true, .help = "Say more" },
    } };
};

/// An IPv4 address and port, read by its own type.
const Address = struct {
    octets: [4]u8,
    port: u16,

    pub const ensign_value = .{ .contract = 1, .expected = "an address such as 10.0.0.1:8080", .parse = parse };

    pub fn parse(bytes: []const u8) ?Address {
        const colon = std.mem.findScalarLast(u8, bytes, ':') orelse return null;
        var out: Address = .{ .octets = undefined, .port = std.fmt.parseInt(u16, bytes[colon + 1 ..], 10) catch return null };
        var parts = std.mem.splitScalar(u8, bytes[0..colon], '.');
        for (&out.octets) |*octet| octet.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
        return if (parts.next() == null) out else null;
    }

    pub fn format(a: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}:{d}", .{ a.octets[0], a.octets[1], a.octets[2], a.octets[3], a.port });
    }
};

const Custom = struct {
    listen: ?Address = null,
    peers: []const Address = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .peers = .{ .delimiter = ',' } } };
};

const Text = struct {
    listen: ?[]const u8 = null,
    peers: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{ .peers = .{ .delimiter = ',' } } };
};

const Color = enum { auto, always, never };

/// Eight options, with requires, a required group and implies.
const Related = struct {
    key: ?[]const u8 = null,
    cert: ?[]const u8 = null,
    ca: ?[]const u8 = null,
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ci: bool = false,
    color: Color = .auto,
    progress: bool = true,
    pub const spec: ensign.Spec(@This()) = .{
        .requires = &.{.{ .option = .key, .needs = &.{ .cert, .ca } }},
        .required_groups = &.{&.{ .token, .password }},
        .implies = &.{.{ .option = .ci, .sets = .{ .color = .never, .progress = false } }},
    };
};

/// The same options with no relations.
const Unrelated = struct {
    key: ?[]const u8 = null,
    cert: ?[]const u8 = null,
    ca: ?[]const u8 = null,
    token: ?[]const u8 = null,
    password: ?[]const u8 = null,
    ci: bool = false,
    color: Color = .auto,
    progress: bool = true,
};

fn branches(c: *ensign.Completion) ensign.Completion.Error!void {
    const names = [_][]const u8{ "main", "maint", "master", "next", "release-1.0", "release-1.1", "topic/one", "topic/two" };
    for (names) |name| if (std.mem.startsWith(u8, name, c.prefix)) try c.add(name, "");
}

const Checkout = struct {
    verbose: u8 = 0,
    command: union(enum) {
        checkout: struct {
            force: bool = false,
            branch: ?[]const u8 = null,
            pub const spec: ensign.Spec(@This()) = .{ .options = .{ .branch = .{ .short = 'b', .complete = branches } } };
        },
    },
    pub const spec: ensign.Spec(@This()) = .{ .name = "git", .options = .{ .verbose = .{ .short = 'v', .count = true } } };
};

const Error = ensign.Error || std.Io.Writer.Error || ensign.ManError || ensign.Completion.Error || error{Unexpected};

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    wide_args: []const []const u8,
    deep_args: []const []const u8,
    list_args: []const []const u8,
    ordinary: []const []const u8 = &.{ "-vv", "build", "-rj8", "--target=x86_64-linux", "a.zig", "b.zig", "c.zig" },
    addresses: []const []const u8 = &.{ "--listen=10.0.0.1:8080", "--peers=10.0.0.2:9000,10.0.0.3:9000,10.0.0.4:9000" },
    related_args: []const []const u8 = &.{ "--key=k.pem", "--cert=c.pem", "--ca=ca.pem", "--token=t", "--ci" },
    out: std.Io.Writer.Discarding,

    fn parse(c: *Context, comptime T: type, args: []const []const u8) Error!void {
        const outcome = try ensign.parse(T, c.gpa, args, .{});
        switch (outcome) {
            .parsed => |v| {
                std.mem.doNotOptimizeAway(&v);
                ensign.free(T, c.gpa, &v);
            },
            else => return error.Unexpected,
        }
    }

    fn wide(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Wide, c.wide_args);
    }

    fn deep(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Deep(8), c.deep_args);
    }

    fn lists(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Wide, c.list_args);
    }

    fn unknown(c: *Context, units: u64) Error!void {
        var diagnostic: ensign.Diagnostic = .{};
        for (0..units) |_| {
            if (ensign.parse(Wide, c.gpa, &.{"--option-12x"}, .{ .diagnostic = &diagnostic })) |_| return error.Unexpected else |err| {
                if (err != error.UnknownOption) return error.Unexpected;
                std.mem.doNotOptimizeAway(&diagnostic);
            }
        }
    }

    fn small(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Small, c.ordinary);
    }

    fn help(c: *Context, units: u64) Error!void {
        for (0..units) |_| try ensign.writeHelp(Small, &c.out.writer, "small", 80);
    }

    fn custom(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Custom, c.addresses);
    }

    fn text(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Text, c.addresses);
    }

    fn related(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Related, c.related_args);
    }

    fn unrelated(c: *Context, units: u64) Error!void {
        for (0..units) |_| try c.parse(Unrelated, c.related_args);
    }

    fn complete(c: *Context, units: u64) Error!void {
        for (0..units) |_| {
            const r = ensign.completionRequest(Checkout, "1:checkout:--branch", &.{ "-v", "checkout", "--force", "--branch", "ma" });
            var completion = r.completion(c.io, c.gpa, null, &c.out.writer);
            try r.answer(&completion);
        }
    }

    fn man(c: *Context, units: u64) Error!void {
        for (0..units) |_| try ensign.writeManPage(Small, &c.out.writer, .{ .date = "2026-10-25", .command = &.{"build"} });
    }
};

/// The bench's own arguments, read by ensign.
const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "parse", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
    } };
};

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    const arena = init.arena.allocator();
    var wide: std.ArrayList([]const u8) = .empty;
    for (0..32) |n| {
        const i = n * 8 + n % 5;
        try wide.append(arena, switch (i % 5) {
            0 => try arena.print("--option-{d}={d}", .{ i, n }),
            1 => try arena.print("--option-{d}", .{i}),
            2 => try arena.print("--option-{d}=high", .{i}),
            3 => try arena.print("--option-{d}=text", .{i}),
            else => try arena.print("--option-{d}=item", .{i}),
        });
    }
    var deep: std.ArrayList([]const u8) = .empty;
    for (0..8) |_| try deep.appendSlice(arena, &.{ "--flag", "--value=7", "next" });
    try deep.appendSlice(arena, &.{ "--name", "leaf" });
    var lists: std.ArrayList([]const u8) = .empty;
    for (0..1000) |_| try lists.append(arena, "--option-4=item");

    var c: Context = .{ .gpa = init.gpa, .io = init.io, .wide_args = wide.items, .deep_args = deep.items, .list_args = lists.items, .out = .init(&.{}) };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const R = shakedown.bench.Row(Context, Error);
    const rows = [_]R{
        .{ .name = "wide/32 of 256 options", .unit = "parse", .run = Context.wide },
        .{ .name = "deep/8 subcommands", .unit = "parse", .run = Context.deep },
        .{ .name = "lists/1000 values", .unit = "parse", .run = Context.lists },
        .{ .name = "errors/unknown among 256", .unit = "parse", .run = Context.unknown },
        .{ .name = "small/command line", .unit = "parse", .run = Context.small },
        .{ .name = "small/help page", .unit = "page", .run = Context.help },
        .{ .name = "custom/address type", .unit = "parse", .run = Context.custom },
        .{ .name = "custom/same text unread", .unit = "parse", .run = Context.text },
        .{ .name = "relations/declared", .unit = "parse", .run = Context.related },
        .{ .name = "relations/none", .unit = "parse", .run = Context.unrelated },
        .{ .name = "complete/answer", .unit = "answer", .run = Context.complete },
        .{ .name = "man/subcommand page", .unit = "page", .run = Context.man },
    };
    try shakedown.bench.run(Error, init.gpa, init.io, &stdout.interface, &c, &rows, .{
        .commit = provenance.commit,
        .cpu = provenance.cpu,
        .os = provenance.os,
    }, .{ .smoke = arguments.smoke, .prefix = arguments.row orelse arguments.prefix orelse "" });
    try stdout.interface.flush();
}
