//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "text", .patterns = &.{"src/text.zig"} },
    .{ .name = "lookup", .patterns = &.{"src/lookup.zig"} },
    .{ .name = "value kinds", .patterns = &.{"src/kinds.zig"} },
    .{ .name = "declaration", .patterns = &.{"src/spec.zig"} },
    .{ .name = "model", .patterns = &.{"src/model.zig"} },
    .{ .name = "values and diagnostics", .patterns = &.{ "src/value.zig", "src/diagnostic.zig" } },
    .{ .name = "help", .patterns = &.{"src/help.zig"} },
    .{ .name = "parser", .patterns = &.{"src/parse.zig"} },
    .{ .name = "rendering and completion", .patterns = &.{ "src/render.zig", "src/complete/tree.zig" } },
    .{ .name = "completion scripts", .patterns = &.{"src/complete/bash.zig"} },
    .{ .name = "completion scripts on bash's lookups", .patterns = &.{ "src/complete/zsh.zig", "src/complete/fish.zig", "src/complete/powershell.zig" } },
    .{ .name = "completion", .patterns = &.{"src/complete.zig"} },
    .{ .name = "process", .patterns = &.{"src/process.zig"} },
    .{ .name = "public", .patterns = &.{"src/ensign.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "builtin",
        "shakedown",
        "xenoglyph",
        "aegis",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &package_references;

pub const required = [_][]const u8{
    "src/text.zig",
    "src/lookup.zig",
    "src/kinds.zig",
    "src/spec.zig",
    "src/model.zig",
    "src/value.zig",
    "src/diagnostic.zig",
    "src/help.zig",
    "src/parse.zig",
    "src/render.zig",
    "src/complete.zig",
    "src/process.zig",
    "src/ensign.zig",
    "src/tests.zig",
};
