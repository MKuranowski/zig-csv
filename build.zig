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

    const bench_module = b.addModule("bench", .{
        .root_source_file = b.path("bench/main.zig"),
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("csv", module);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });
    const bench_exe_install = b.addInstallArtifact(bench_exe, .{});
    const bench_build_step = b.step("bench-exe", "Build benchmarking utility");
    bench_build_step.dependOn(&bench_exe_install.step);

    const bench_exe_run = b.addRunArtifact(bench_exe);
    const bench_run_step = b.step("bench", "Run benchmarking utility");
    bench_run_step.dependOn(&bench_exe_run.step);
}
