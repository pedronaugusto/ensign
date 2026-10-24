const std = @import("std");

/// What a project that depends on ensign builds: the `ensign` module and its
/// library. The tests, example, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Text in help is measured in the columns a terminal gives it: xenoglyph's widths.
    const xenoglyph = b.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph");
    // aegis's checked scalars are values a command line gives: ranged integers, durations, sizes.
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const module = b.addModule("ensign", .{ .root_source_file = b.path("src/ensign.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "xenoglyph", .module = xenoglyph }, .{ .name = "aegis", .module = aegis } } });
    b.installArtifact(b.addLibrary(.{ .name = "ensign", .root_module = module }));
}

/// ensign's development: its tests, example, checks and benchmarks under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("ensign", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("ensign");
    const library = package.artifact("ensign");
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const tests = b.addTest(.{
        .name = "ensign-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
                .{ .name = "xenoglyph", .module = p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph") },
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            },
        }),
    });
    const check = b.step("check", "Compile the tests, library, example and benchmarks without running them");
    const test_step = b.step("test", "Run the tests and example");
    const unit_run = b.addRunArtifact(tests);
    test_step.dependOn(&unit_run.step);
    // The suite alone, every binary of it holding properties: what the
    // hardened profile fuzzes.
    b.step("unit", "Run the ensign suite alone").dependOn(&unit_run.step);
    check.dependOn(&tests.step);
    check.dependOn(&library.step);

    // A declaration the parser cannot read unambiguously does not compile,
    // and the error names what to change.
    const declarations = b.step("check-declarations", "Reject declarations that cannot be parsed unambiguously");
    for (rejected) |case| {
        const source = b.pathJoin(&.{ "ci", "declarations", b.fmt("{s}.zig", .{case.name}) });
        const object = b.addObject(.{ .name = b.fmt("reject-{s}", .{case.name}), .root_module = b.createModule(.{
            .root_source_file = p.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ensign", .module = module }},
        }) });
        object.expect_errors = .{ .contains = case.error_text };
        declarations.dependOn(&object.step);
    }
    check.dependOn(declarations);
    test_step.dependOn(declarations);

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ensign", .module = module }, .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") } } }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    const run_example = b.addRunArtifact(example);
    run_example.addArgs(&.{ "--verbose", "build", "-j", "4", "--timeout=1m30s", "--target=x86_64-linux", "src/main.zig" });
    run_example.expectStdOutEqual("verbose=1 color=auto jobs=4 timeout=1m30s target=x86_64-linux files=1\n");
    examples.dependOn(&run_example.step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    // Parsing a slice, help and completions need no operating system.
    const freestanding = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const free_package = b.dependency("ensign", .{ .target = freestanding, .optimize = .small });
    const object = b.addObject(.{ .name = "ensign-freestanding", .root_module = b.createModule(.{
        .root_source_file = p.path("ci/freestanding.zig"),
        .target = freestanding,
        .optimize = .small,
        .imports = &.{ .{ .name = "ensign", .module = free_package.module("ensign") }, .{ .name = "aegis", .module = free_package.builder.dependency("aegis", .{ .target = freestanding, .optimize = .small }).module("aegis") } },
    }) });
    b.step("check-freestanding", "Build parsing, help and completions for wasm32-freestanding").dependOn(&object.step);
    b.getInstallStep().dependOn(&tests.step);
    b.getInstallStep().dependOn(&example.step);

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        // The completion tests require bash on Linux, the riscv64 machine's too.
        .vm_packages = &.{"bash"},
        // The release tier runs the suite with safety on, fuzzes its
        // properties and runs it under ThreadSanitizer.
        .hardened = .{ .fuzz_step = "unit", .tsan_step = "unit" },
        .bench = .{
            .programs = &.{.{ .name = "parse", .source = "bench/parse.zig" }},
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on ensign by path, with no packages to fetch:
    // the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{ .package = "ensign", .program = p.path("ci/consumer.zig"), .modules = &.{"ensign"}, .packages = &.{ p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }), p.dependency("aegis", .{ .target = target, .optimize = optimize }) } });
}

/// Each rejected declaration and how its compile error ends.
const rejected = [_]struct { name: []const u8, error_text: []const u8 }{
    .{ .name = "two_commands", .error_text = "has two subcommand fields; a command has at most one" },
    .{ .name = "same_short", .error_text = "-j names two options" },
    .{ .name = "list_not_last", .error_text = "a list positional takes the rest, so it comes last" },
    .{ .name = "positional_and_commands", .error_text = "a command with subcommands takes no positionals" },
    .{ .name = "bool_without_default", .error_text = "a boolean needs a default, or `?bool` to tell absent from false" },
    .{ .name = "global_hidden_below", .error_text = "--color hides the global option of global_hidden_below.T" },
    .{ .name = "name_with_space", .error_text = "must start with a letter or digit and hold only letters, digits, '-', '_', '.' or '+'" },
    .{ .name = "unsupported_type", .error_text = "is no command-line value; use an integer, float, enum, bool, []const u8, an aegis integer, Duration or Bytes, or a slice of one" },
    .{ .name = "nonexhaustive_enum", .error_text = "is a non-exhaustive enum, whose values have no names to read; make it exhaustive, or use an aegis integer, Duration or Bytes" },
    .{ .name = "untyped_spec", .error_text = "must be declared `pub const spec: ensign.Spec(@This())`" },
    .{ .name = "global_hides_builtin", .error_text = "its -V flag hides the global option of global_hides_builtin.T" },
};

/// ensign again, in the mode a benchmark builds in: an imported module keeps
/// its own mode, so a ReleaseFast benchmark over the Debug module would time
/// the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const ensign = b.dependency("ensign", .{ .target = target, .optimize = optimize }).module("ensign");
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "ensign", .module = ensign }}) catch @panic("OOM");
}
