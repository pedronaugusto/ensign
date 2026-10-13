//! A value written back as the command line that parses to it: for starting
//! a child process with the arguments a program holds.
const std = @import("std");
const model = @import("model.zig");
const value = @import("value.zig");
const Allocator = std.mem.Allocator;

pub const RenderError = error{
    /// The value holds what no command line gives: a count below its
    /// default, a flag false that cannot be negated, a null or empty list
    /// where the default is not, a list item holding its delimiter.
    Unrepresentable,
    OutOfMemory,
};

/// The arguments, after the program's name, that parse to `v`: each option
/// whose value is not its default as `--long=value`, flags as `--long` or
/// `--no-long`, then the subcommand, or the positionals after `--` when
/// one starts with `-`. Everything is allocated in `arena`; text is copied
/// only when joined to an option's name.
pub fn render(comptime T: type, arena: Allocator, v: T) RenderError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try command(T, arena, &out, v);
    return out.toOwnedSlice(arena);
}

fn command(comptime T: type, arena: Allocator, out: *std.ArrayList([]const u8), v: T) RenderError!void {
    const i = comptime model.info(T);
    inline for (i.options) |o| try option(o, arena, out, @field(v, o.field));
    var dashed = false;
    inline for (i.positionals) |p| {
        const field = @field(v, p.field);
        if (p.kind == .list) {
            for (field) |item| {
                if (splits(p, item)) return error.Unrepresentable;
                try positional(p, arena, out, item, &dashed);
            }
        } else if (p.optional) {
            if (field) |item| try positional(p, arena, out, item, &dashed);
        } else try positional(p, arena, out, field, &dashed);
    }
    const commands = comptime i.commands;
    if (commands) |c| {
        const u = if (c.optional) (@field(v, c.field) orelse return) else @field(v, c.field);
        switch (u) {
            inline else => |payload, tag| {
                const sub = comptime for (c.list) |sub| {
                    if (std.mem.eql(u8, sub.tag, @tagName(tag))) break sub;
                } else unreachable;
                try out.append(arena, sub.name);
                if (@TypeOf(payload) != void) try command(@TypeOf(payload), arena, out, payload);
            },
        }
    }
}

fn option(comptime o: model.Opt, arena: Allocator, out: *std.ArrayList([]const u8), field: o.Field) RenderError!void {
    const d: ?o.Field = comptime o.default() orelse if (o.optional) @as(o.Field, null) else null;
    switch (o.kind) {
        .flag => {
            const now: ?bool = field;
            const was: ?bool = if (d) |dv| dv else null;
            if (now == was) return;
            const set = now orelse return error.Unrepresentable;
            if (set) return out.append(arena, "--" ++ o.long);
            if (!o.meta.negatable) return error.Unrepresentable;
            return out.append(arena, "--no-" ++ o.long);
        },
        .count => {
            const base = d.?;
            if (field < base) return error.Unrepresentable;
            for (0..field - base) |_| try out.append(arena, "--" ++ o.long);
        },
        .single => {
            if (!o.required and equal(o.Field, field, d.?)) return;
            const one = if (o.optional) field orelse return error.Unrepresentable else field;
            try out.append(arena, try joined(o, arena, one));
        },
        .list => {
            if (!o.required and equal(o.Field, field, d.?)) return;
            if (field.len == 0) return error.Unrepresentable;
            for (field) |item| {
                if (splits(o, item)) return error.Unrepresentable;
                try out.append(arena, try joined(o, arena, item));
            }
        },
    }
}

/// Whether a list item holds its option's delimiter, so that parsing it
/// back would make several.
fn splits(comptime o: model.Opt, item: o.Value) bool {
    const d = o.meta.delimiter orelse return false;
    if (@typeInfo(o.Value) != .pointer) return false;
    return std.mem.findScalar(u8, item, d) != null;
}

fn joined(comptime o: model.Opt, arena: Allocator, item: o.Value) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    w.writer.writeAll("--" ++ o.long ++ "=") catch return error.OutOfMemory;
    value.write(o.Value, &w.writer, item) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

fn positional(comptime p: model.Opt, arena: Allocator, out: *std.ArrayList([]const u8), item: p.Value, dashed: *bool) Allocator.Error!void {
    const bytes = if (@typeInfo(p.Value) == .pointer) item else blk: {
        var w: std.Io.Writer.Allocating = .init(arena);
        errdefer w.deinit();
        value.write(p.Value, &w.writer, item) catch return error.OutOfMemory;
        break :blk try w.toOwnedSlice();
    };
    if (!dashed.* and bytes.len > 1 and bytes[0] == '-') {
        try out.append(arena, "--");
        dashed.* = true;
    }
    try out.append(arena, bytes);
}

/// Value equality for fields: text by bytes, lists element by element,
/// floats by bits so that NaN equals itself.
pub fn equal(comptime F: type, a: F, b: F) bool {
    switch (@typeInfo(F)) {
        .optional => |opt| {
            if (a == null or b == null) return a == null and b == null;
            return equal(opt.child, a.?, b.?);
        },
        .pointer => |ptr| {
            if (a.len != b.len) return false;
            if (ptr.child == u8) return std.mem.eql(u8, a, b);
            for (a, b) |x, y| if (!equal(ptr.child, x, y)) return false;
            return true;
        },
        .float => |f| return @as(@Int(.unsigned, f.bits), @bitCast(a)) == @as(@Int(.unsigned, f.bits), @bitCast(b)),
        // aegis's `Checked` and `Saturating` hold their integer in a struct.
        .@"struct" => return std.meta.eql(a, b),
        else => return a == b,
    }
}

test "render a value" {
    const Mode = enum { fast, safe_mode };
    const T = struct {
        verbose: u8 = 0,
        mode: Mode = .fast,
        name: ?[]const u8 = null,
        color: bool = true,
        files: []const []const u8 = &.{},
        pub const spec: @import("spec.zig").Spec(@This()) = .{ .options = .{
            .verbose = .{ .count = true },
            .files = .{ .positional = true },
        } };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = try render(T, arena.allocator(), .{ .verbose = 2, .mode = .safe_mode, .name = "x", .color = false, .files = &.{ "a", "-b" } });
    const want = [_][]const u8{ "--verbose", "--verbose", "--mode=safe-mode", "--name=x", "--no-color", "a", "--", "-b" };
    try std.testing.expectEqual(want.len, args.len);
    for (want, args) |w, a| try std.testing.expectEqualStrings(w, a);
}
