//! Build Configuration.
//!
//! Orchestrates kernel, libs, and test builds for ARM64 and RISC-V targets.

const std = @import("std");
const boards = @import("build/boards.zig");

pub fn build(b: *std.Build) void {
    var query = b.standardTargetOptionsQueryOnly(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name") orelse null;
    const board = b.option([]const u8, "board", "Board name (default: qemu_virt)") orelse "qemu_virt";

    // Disable FP for kernel code - no floating-point in kernel.
    // Any accidental FP use becomes a compile error.
    switch (query.cpu_arch orelse .aarch64) {
        .aarch64 => {
            query.cpu_features_sub = std.Target.aarch64.featureSet(&.{ .neon, .fp_armv8 });
        },
        .riscv64 => {
            query.cpu_features_sub = std.Target.riscv.featureSet(&.{ .f, .d });
        },
        else => {},
    }
    const target = b.resolveTargetQuery(query);

    const arch = switch (target.result.cpu.arch) {
        .aarch64 => boards.Arch.arm64,
        .riscv64 => boards.Arch.riscv64,
        else => @panic("Unsupported architecture"),
    };
    const board_info = boards.find(board, arch) orelse @panic("Unknown board for target arch");

    // libfdt - read-only subset for parsing bootloader DTB
    const libfdt_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = false });
    const cflags: []const []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => &.{ "-ffreestanding", "-nostdlib", "-include", "src/kernel/fdt/libfdt_env.h" },
        .riscv64 => &.{ "-ffreestanding", "-nostdlib", "-mcmodel=medany", "-include", "src/kernel/fdt/libfdt_env.h" },
        else => @panic("Unsupported architecture for libfdt"),
    };
    libfdt_module.addCSourceFiles(.{
        .files = &.{ "lib/dtc/libfdt/fdt.c", "lib/dtc/libfdt/fdt_ro.c", "lib/dtc/libfdt/fdt_strerror.c" },
        .flags = cflags,
    });
    libfdt_module.addIncludePath(b.path("lib/dtc/libfdt"));
    const libfdt = b.addLibrary(.{ .linkage = .static, .name = "fdt", .root_module = libfdt_module });

    // Board module - injected as dependency so kernel code imports via @import("board").
    const board_module = b.createModule(.{
        .root_source_file = b.path(board_info.board_zig),
        .target = target,
        .optimize = optimize,
    });

    // Single kernel module with board dependency.
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "board", .module = board_module },
        },
    });

    const kernel = b.addExecutable(.{
        .name = switch (target.result.cpu.arch) {
            .aarch64 => "kernel-arm64",
            .riscv64 => "kernel-riscv64",
            else => "kernel",
        },
        .root_module = kernel_module,
    });
    kernel.entry = .disabled;

    // Link libfdt (Zig bindings in src/kernel/fdt/fdt.zig)
    kernel.linkLibrary(libfdt);

    // Linker script for memory layout.
    kernel.setLinkerScript(b.path(board_info.linker_script));

    if (target.result.cpu.arch == .riscv64) {
        kernel.root_module.code_model = .medium;
    }

    const base_name = artifactBaseName(b, arch, board, optimize);
    const elf_name = b.fmt("{s}.elf", .{base_name});
    const install_kernel = b.addInstallArtifact(kernel, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = b.fmt("kernel/{s}", .{elf_name}),
    });
    b.getInstallStep().dependOn(&install_kernel.step);

    const bin_name = b.fmt("{s}.bin", .{base_name});
    const objcopy = b.addSystemCommand(&.{ "llvm-objcopy", "-O", "binary" });
    objcopy.addFileArg(kernel.getEmittedBin());
    const objcopy_out = objcopy.addOutputFileArg(bin_name);
    b.getInstallStep().dependOn(&objcopy.step);
    const install_bin = b.addInstallFile(objcopy_out, b.fmt("kernel/{s}", .{bin_name}));
    b.getInstallStep().dependOn(&install_bin.step);

    // Tests run on host (native target).
    const test_step = b.step("test", "Run all tests");
    const native_target = b.resolveTargetQuery(.{});
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/test.zig"),
        .target = native_target,
    });
    const kernel_tests = b.addTest(.{
        .root_module = test_module,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    test_step.dependOn(&b.addRunArtifact(kernel_tests).step);

    // Smoke test runner (runs on host, spawns QEMU)
    const smoke_step = b.step("smoke", "Run smoke tests");
    const boards_module = b.createModule(.{
        .root_source_file = b.path("build/boards.zig"),
        .target = native_target,
        .optimize = .Debug,
    });
    const smoke_module = b.createModule(.{
        .root_source_file = b.path("tests/smoke.zig"),
        .target = native_target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "boards", .module = boards_module },
        },
    });
    const smoke_exe = b.addExecutable(.{
        .name = "smoke",
        .root_module = smoke_module,
    });
    const run_smoke = b.addRunArtifact(smoke_exe);
    if (b.args) |args| {
        run_smoke.addArgs(args);
    }
    smoke_step.dependOn(&run_smoke.step);

    _ = buildUserspace(b);
}

fn optimizeTag(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => "release",
    };
}

fn artifactBaseName(
    b: *std.Build,
    arch: boards.Arch,
    board: []const u8,
    optimize: std.builtin.OptimizeMode,
) []const u8 {
    const arch_tag = boards.archTag(arch);
    const optimize_tag = optimizeTag(optimize);
    return b.fmt("{s}-{s}-{s}", .{ arch_tag, board, optimize_tag });
}

fn buildUserspace(b: *std.Build) *std.Build.Step {
    return b.step("userspace", "Build userspace programs (stub)");
}
