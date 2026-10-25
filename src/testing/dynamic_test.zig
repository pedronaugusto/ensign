//! Completions the program answers: which key reaches which completer, the
//! request a script makes, the answer's lines, and the scripts asking a
//! program in the real shells.
const std = @import("std");
const ensign = @import("../ensign.zig");
const shells = @import("shells.zig");
const shake = @import("shakedown");

const Shade = enum { light, dark };

fn branches(c: *ensign.Completion) ensign.Completion.Error!void {
    for ([_][]const u8{ "main", "maint", "next" }) |b| if (std.mem.startsWith(u8, b, c.prefix)) try c.add(b, "a branch");
}

fn remotes(c: *ensign.Completion) ensign.Completion.Error!void {
    if (c.args.len == 0) return c.fail("no words before the remote");
    try c.add("origin", "");
}

/// A host name that completes itself wherever it is a field's type.
pub const Host = struct {
    name: []const u8,
    pub const ensign_value = .{ .contract = 1, .expected = "a host", .parse = parse, .complete = hosts };
    pub fn parse(bytes: []const u8) ?Host {
        return if (bytes.len == 0) null else .{ .name = bytes };
    }
    pub fn format(h: Host, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(h.name);
    }
    fn hosts(c: *ensign.Completion) ensign.Completion.Error!void {
        try c.add("alpha.example", "");
    }
};

const Checkout = struct {
    branch: ?[]const u8 = null,
    shade: Shade = .light,
    host: ?Host = null,
    paths: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{ .options = .{
        .branch = .{ .short = 'b', .aliases = &.{"ref"}, .complete = branches },
        .paths = .{ .positional = true, .complete = branches },
    } };
};

const Dyn = struct {
    remote: ?[]const u8 = null,
    command: union(enum) { checkout: Checkout },
    pub const spec: ensign.Spec(@This()) = .{ .name = "dyn", .options = .{ .remote = .{ .global = true, .complete = remotes } } };
};

fn answer(asked: []const u8, words: []const []const u8, out: []u8) ![]const u8 {
    const r = ensign.completionRequest(Dyn, asked, words);
    var w: std.Io.Writer = .fixed(out);
    var c = r.completion(std.testing.io, std.testing.allocator, null, &w);
    try r.answer(&c);
    return w.buffered();
}

test "each spelling of an option reaches its completer, and a list positional every index from its own" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("main\ta branch\nmaint\ta branch\n", try answer("1:checkout:--branch", &.{ "checkout", "--branch", "ma" }, &buffer));
    try std.testing.expectEqualStrings("main\ta branch\nmaint\ta branch\n", try answer("1:checkout:-b", &.{ "checkout", "-b", "ma" }, &buffer));
    try std.testing.expectEqualStrings("next\ta branch\n", try answer("1:checkout:--ref", &.{ "checkout", "--ref", "n" }, &buffer));
    try std.testing.expectEqualStrings("next\ta branch\n", try answer("1:checkout:#0", &.{ "checkout", "n" }, &buffer));
    try std.testing.expectEqualStrings("next\ta branch\n", try answer("1:checkout:#5", &.{ "checkout", "a", "b", "n" }, &buffer));
    // A global option completes below its command too.
    try std.testing.expectEqualStrings("origin\n", try answer("1:checkout:--remote", &.{ "checkout", "--remote", "" }, &buffer));
    // A type that completes itself does so wherever it is a field.
    try std.testing.expectEqualStrings("alpha.example\n", try answer("1:checkout:--host", &.{ "checkout", "--host", "" }, &buffer));
}

test "a request names its failure: another protocol, a key nothing completes, a completer that cannot answer" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    inline for (.{ .{ "2:checkout:--branch", "protocol" }, .{ "1:checkout:--shade", "nothing here completes" }, .{ "1::--remote", "no words before" } }) |case| {
        const r = ensign.completionRequest(Dyn, case[0], &.{""});
        var c = r.completion(std.testing.io, std.testing.allocator, null, &w);
        try std.testing.expectError(error.Failed, r.answer(&c));
        try std.testing.expect(std.mem.find(u8, c.failure, case[1]) != null);
    }
}

test "the request holds the words before the cursor and the word completed" {
    const r = ensign.completionRequest(Dyn, "1:checkout:--branch", &.{ "checkout", "--branch", "ma" });
    try std.testing.expectEqualStrings("checkout:--branch", r.key);
    try std.testing.expectEqual(2, r.args.len);
    try std.testing.expectEqualStrings("ma", r.prefix);
    const empty = ensign.completionRequest(Dyn, "1:checkout:#0", &.{});
    try std.testing.expectEqualStrings("", empty.prefix);
}

test "completions keep enum values, hints and subcommands static" {
    const tree = @import("../complete/tree.zig");
    const nodes = comptime tree.nodes(Dyn);
    try std.testing.expectEqual(tree.Kind.program, nodes[1].entries[0].kind);
    try std.testing.expectEqual(tree.Kind.values, nodes[1].entries[1].kind);
    try std.testing.expectEqual(tree.Kind.program, nodes[1].positionals[0].kind);
}

/// A stand-in for the program: answers with the key and the words it was
/// given, joined by `+`, then two branches, filtered by the word completed.
const program =
    \\#!/bin/sh
    \\for last in "$@"; do :; done
    \\words="$ENSIGN_COMPLETE"
    \\for a in "$@"; do words="$words+$a"; done
    \\case "key=$words" in "$last"*) printf 'key=%s\tthe request\n' "$words" ;; esac
    \\case main in "$last"*) printf 'main\tThe main branch\n' ;; esac
    \\case maint in "$last"*) printf 'maint\n' ;; esac
    \\
;

const cases = [_]shells.Case{
    .{ .line = "dyn checkout --branch ", .want = "key=1:checkout:--branch+checkout+--branch+ main maint" },
    .{ .line = "dyn checkout --branch ma", .want = "main maint" },
    .{ .line = "dyn checkout --branch=ma", .want = "--branch=main --branch=maint" },
    .{ .line = "dyn checkout -b ", .want = "key=1:checkout:-b+checkout+-b+ main maint", .fish = "key=1:checkout:--branch+checkout+-b+ main maint" },
    .{ .line = "dyn --remote=o checkout x ", .want = "key=1:checkout:#1+--remote=o+checkout+x+ main maint", .fish = "key=1:checkout:#0+--remote=o+checkout+x+ main maint" },
    .{ .line = "dyn checkout --sh", .want = "--shade" },
    .{ .line = "dyn checkout --shade ", .want = "dark light" },
};

test "bash asks the program" {
    try shells.checkWith(Dyn, .bash, "dyn", &cases, program);
}

test "zsh asks the program" {
    try shells.checkWith(Dyn, .zsh, "dyn", &cases, program);
}

test "fish asks the program" {
    try shells.checkWith(Dyn, .fish, "dyn", &cases, program);
}

test "PowerShell asks the program" {
    try shells.checkWith(Dyn, .powershell, "dyn", &cases, program);
}

fn arbitraryRequest(_: void, c: *shake.Case) !void {
    const pieces = [_][]const u8{ "1", "2", ":", "checkout", "--branch", "-b", "--ref", "#", "0", "5", "--remote", "--host", " ", "\xff" };
    var asked: std.ArrayList(u8) = .empty;
    for (0..shake.gen.intRange(c.source, usize, 0, 6)) |_| try asked.appendSlice(c.gpa, shake.gen.oneOf(c.source, []const u8, &pieces));
    const words = try c.gpa.alloc([]const u8, shake.gen.intRange(c.source, usize, 0, 4));
    for (words) |*w| w.* = try shake.gen.string(c.source, c.gpa, .{ .kind = .bytes, .max_len = 6 });
    const r = ensign.completionRequest(Dyn, asked.items, words);
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var completion = r.completion(std.testing.io, c.gpa, null, &w);
    r.answer(&completion) catch |err| {
        try std.testing.expectEqual(error.Failed, err);
        try std.testing.expect(completion.failure.len != 0);
    };
}

test "any request is answered or refused with a reason" {
    try shake.check(std.testing.allocator, {}, arbitraryRequest, .{ .cases = 3000 });
}
