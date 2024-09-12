const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // support both zig versions 0.12.0-dev.2063+804cee3b9 and 0.13.0
    const root_source_file = if (@hasDecl(std.Build, "path")) b.path("src/root.zig") else .{ .path = "src/root.zig" };

    const module = b.addModule("stenway-formats", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    _ = module;

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
