//! Text a person reads: bytes shown safely, how wide they are, where lines
//! break, and which known name is closest to a mistyped one.
const std = @import("std");
const Writer = std.Io.Writer;
const xenoglyph = @import("xenoglyph");

/// Writes `bytes` so a terminal shows them as they are: printable UTF-8
/// stays; control characters, bidirectional controls and bytes that are not
/// UTF-8 (an unpaired surrogate in WTF-8 among them) are written `\xNN`.
pub fn writeEscaped(w: *Writer, bytes: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 1 and i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..len]) and !control(bytes[i..][0..len])) {
            try w.writeAll(bytes[i..][0..len]);
            i += len;
            continue;
        }
        const c = bytes[i];
        if (len == 1 and c >= 0x20 and c != 0x7f) {
            try w.writeByte(c);
        } else {
            try w.print("\\x{x:0>2}", .{c});
        }
        i += 1;
    }
}

/// A C1 control (U+0080 to U+009F) or a bidirectional control (U+202A to
/// U+202E, U+2066 to U+2069): characters that change how a terminal shows
/// what follows them.
fn control(sequence: []const u8) bool {
    if (sequence.len == 2) return sequence[0] == 0xc2 and sequence[1] < 0xa0;
    if (sequence.len != 3 or sequence[0] != 0xe2) return false;
    return (sequence[1] == 0x80 and sequence[2] >= 0xaa and sequence[2] <= 0xae) or (sequence[1] == 0x81 and sequence[2] >= 0xa6 and sequence[2] <= 0xa9);
}

/// A `{f}` formatter for `writeEscaped`.
pub fn escaped(bytes: []const u8) std.fmt.Alt([]const u8, formatEscaped) {
    return .{ .data = bytes };
}

fn formatEscaped(bytes: []const u8, w: *Writer) Writer.Error!void {
    return writeEscaped(w, bytes);
}

/// Columns `bytes` take in a terminal: the sum of its grapheme clusters', as
/// xenoglyph measures them (a CJK ideograph 2, a combining mark 0, an emoji
/// 2, a control 0).
pub fn width(bytes: []const u8) usize {
    return xenoglyph.width.string(bytes, .{}).raw();
}

/// How far compile-time reading of a declaration may go: a declaration of
/// hundreds of options takes millions of branches, which is still quick.
pub const branch_quota = 50_000_000;

/// The longest name `distance` compares; a longer one is never suggested.
pub const max_compared = 64;

/// Optimal string alignment distance: insertions, deletions, substitutions
/// and transpositions of neighbours, each costing one. Null when either side
/// is longer than `max_compared`. Allocates nothing.
pub fn distance(a: []const u8, b: []const u8) ?usize {
    if (a.len > max_compared or b.len > max_compared) return null;
    var rows: [3][max_compared + 1]usize = undefined;
    var before = &rows[0];
    var previous = &rows[1];
    var current = &rows[2];
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 1..) |ca, i| {
        current[0] = i;
        for (b, 1..) |cb, j| {
            const cost: usize = @intFromBool(ca != cb);
            var best = @min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost);
            if (i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb) best = @min(best, before[j - 2] + 1);
            current[j] = best;
        }
        const spent = before;
        before = previous;
        previous = current;
        current = spent;
    }
    return previous[b.len];
}

/// Whether `known` is close enough to `typed` to suggest: at most a third
/// of the longer name's bytes differ, and at least one byte stays.
pub fn close(typed: []const u8, known: []const u8) ?usize {
    const d = distance(typed, known) orelse return null;
    const longer = @max(typed.len, known.len);
    if (d == 0 or d * 3 > longer) return null;
    return d;
}

/// The nearest of `candidates` to `typed`, the first on a tie.
pub const Nearest = struct {
    typed: []const u8,
    best: ?[]const u8 = null,
    cost: usize = std.math.maxInt(usize),

    pub fn consider(n: *Nearest, candidate: []const u8) void {
        const d = close(n.typed, candidate) orelse return;
        if (d < n.cost) {
            n.cost = d;
            n.best = candidate;
        }
    }
};

/// Writes `text` from column `indent`, breaking lines where a line may break
/// so none passes `limit` columns, unless one piece alone is longer. A newline
/// in `text` breaks the line; each new line starts at `indent`. `column` is
/// where the writer stands on entry; the column the text ends at is returned.
/// Spaces between pieces are written as one; pieces with none between them,
/// as ideographs have, are written together.
pub fn wrap(w: *Writer, text: []const u8, indent: usize, column: usize, limit: usize) Writer.Error!usize {
    var col = column;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) {
            try w.writeByte('\n');
            col = 0;
        }
        first_line = false;
        var pieces: Pieces = .{ .line = line, .breaks = xenoglyph.lines(line) };
        var first = true;
        while (pieces.next()) |piece| {
            const wide = wordWidth(piece.bytes);
            if (col < indent) {
                try w.splatByteAll(' ', indent - col);
                col = indent;
            } else if (!first or col > indent) {
                const gap: usize = @intFromBool(first or piece.spaced);
                if (col + gap + wide > limit and col > indent) {
                    try w.writeByte('\n');
                    try w.splatByteAll(' ', indent);
                    col = indent;
                } else {
                    try w.splatByteAll(' ', gap);
                    col += gap;
                }
            }
            try writeWord(w, piece.bytes);
            col += wide;
            first = false;
        }
    }
    return col;
}

/// What `wrap` places whole: the text between two places a line may break,
/// without the spaces around it.
const Piece = struct {
    bytes: []const u8,
    /// Spaces stood before it.
    spaced: bool,
};

/// The pieces of a line, at xenoglyph's line break opportunities (UAX #14)
/// with two kept together: none next to a glue, and none between two
/// printable ASCII characters, so an option, a path or a hyphenated word
/// stays whole as it is typed, and ASCII text breaks only at spaces.
const Pieces = struct {
    line: []const u8,
    breaks: xenoglyph.line.Iterator,
    spaced: bool = false,

    fn next(p: *Pieces) ?Piece {
        while (true) {
            const start: usize = p.breaks.offset().raw();
            var end: usize = start;
            while (p.breaks.nextSpan()) |span| {
                end = span.end.raw();
                if (end == p.line.len or !kept(p.line[end - 1], p.line[end])) break;
            }
            if (end == start) return null;
            const raw = p.line[start..end];
            const bytes = std.mem.trim(u8, raw, " ");
            const spaced = p.spaced or (bytes.len != 0 and raw[0] == ' ');
            p.spaced = bytes.len == 0 or raw[raw.len - 1] == ' ';
            if (bytes.len == 0) continue;
            return .{ .bytes = bytes, .spaced = spaced };
        }
    }

    fn kept(before: u8, after: u8) bool {
        if (before == glue[0] or after == glue[0]) return true;
        return printable(before) and printable(after);
    }

    fn printable(c: u8) bool {
        return c > ' ' and c < 0x7f;
    }
};

/// Joins two words `wrap` keeps on one line; it is written as a space.
pub const glue = "\x1f";

/// A word's columns as `writeWord` writes it: each glue is a space.
fn wordWidth(word: []const u8) usize {
    var parts = std.mem.splitScalar(u8, word, glue[0]);
    var wide = width(parts.first());
    while (parts.next()) |part| wide += 1 + width(part);
    return wide;
}

fn writeWord(w: *Writer, word: []const u8) Writer.Error!void {
    var parts = std.mem.splitScalar(u8, word, glue[0]);
    try w.writeAll(parts.first());
    while (parts.next()) |part| {
        try w.writeByte(' ');
        try w.writeAll(part);
    }
}

/// `name` with each `_` written `-`, at compile time.
pub fn dashed(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var out: [name.len]u8 = name[0..name.len].*;
        for (&out) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const final = out;
        break :blk &final;
    };
}

/// `name` in capitals with `-` for `_`, at compile time.
pub fn upper(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var out: [name.len]u8 = name[0..name.len].*;
        for (&out) |*c| c.* = if (c.* == '_') '-' else std.ascii.toUpper(c.*);
        const final = out;
        break :blk &final;
    };
}

test "escaped bytes" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeEscaped(&w, "é\x01a\xff\xed\xa0\x80\xc2\x9b\xe2\x80\xae");
    try std.testing.expectEqualStrings("é\\x01a\\xff\\xed\\xa0\\x80\\xc2\\x9b\\xe2\\x80\\xae", w.buffered());
}

test "distance" {
    try std.testing.expectEqual(@as(?usize, 1), distance("verbos", "verbose"));
    try std.testing.expectEqual(@as(?usize, 1), distance("ab", "ba"));
    try std.testing.expectEqual(@as(?usize, 3), distance("", "abc"));
    try std.testing.expectEqual(@as(?usize, 0), distance("same", "same"));
    try std.testing.expectEqual(@as(?usize, null), close("x", "y"));
    try std.testing.expectEqual(@as(?usize, 1), close("colr", "color"));
}

test "width is the columns a terminal gives" {
    try std.testing.expectEqual(@as(usize, 4), width("日本"));
    try std.testing.expectEqual(@as(usize, 1), width("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), width("👍🏽"));
    try std.testing.expectEqual(@as(usize, 6), comptime width("--jobs"));
}

test "wrap measures wide text and counts glue as a space" {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    // 日本語 is six columns and may break between its ideographs: "  a 日"
    // ends at six, 本 would end at eight, past seven.
    try std.testing.expectEqual(@as(usize, 3), try wrap(&w, "a 日本語 b", 2, 0, 7));
    try std.testing.expectEqualStrings("  a 日\n  本語\n  b", w.buffered());
    w = .fixed(&buffer);
    try std.testing.expectEqual(@as(usize, 12), try wrap(&w, "[default:" ++ glue ++ "1]", 0, 0, 80));
    try std.testing.expectEqualStrings("[default: 1]", w.buffered());
}

test "wrap breaks CJK text where a line may break, and never inside glued or ASCII words" {
    var buffer: [256]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    // Ten columns hold five ideographs; no line may start with the full stop,
    // which stays with the ideograph before it.
    const sentence = "日本語のテキストは改行できます。";
    _ = try wrap(&w, sentence, 0, 0, 10);
    var joined: [128]u8 = undefined;
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(width(line) <= 10);
        try std.testing.expect(!std.mem.startsWith(u8, line, "。"));
        @memcpy(joined[len..][0..line.len], line);
        len += line.len;
    }
    try std.testing.expectEqualStrings(sentence, joined[0..len]);
    try std.testing.expectEqual(@as(usize, 4), count);
    w = .fixed(&buffer);
    _ = try wrap(&w, "use --dry-run or well-known [env:" ++ glue ++ "APP_DRY_RUN]", 0, 0, 12);
    try std.testing.expectEqualStrings("use\n--dry-run or\nwell-known\n[env: APP_DRY_RUN]", w.buffered());
    w = .fixed(&buffer);
    _ = try wrap(&w, "a  b   c", 0, 0, 80);
    try std.testing.expectEqualStrings("a b c", w.buffered());
}
