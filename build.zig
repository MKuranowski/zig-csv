const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("csv", .{
        .root_source_file = b.path("csv.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_test = b.addTest(.{ .root_module = module });
    const lib_test_run = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&lib_test_run.step);

    const lib_static = b.addLibrary(.{
        .name = "csv",
        .root_module = module,
        .linkage = .static,
    });
    const lib_docs = b.addInstallDirectory(.{
        .source_dir = lib_static.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate library docs");
    docs_step.dependOn(&lib_docs.step);
}
