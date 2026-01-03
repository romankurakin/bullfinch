const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name") orelse null;
    const board = b.option([]const u8, "board", "Board name (default: qemu_virt)") orelse "qemu_virt";

    const arch_dir = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .riscv64 => "riscv64",
        else => @panic("Unsupported architecture"),
    };

    // Board module - injected as dependency so kernel code imports via @import("board").
    const board_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "boards", board, "board.zig" });
    const board_module = b.createModule(.{
        .root_source_file = b.path(board_path),
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

    // Linker script for memory layout.
    const linker_script_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "boards", board, "kernel.ld" });
    kernel.setLinkerScript(b.path(linker_script_path));

    if (target.result.cpu.arch == .riscv64) {
        kernel.root_module.code_model = .medium;
    }

    b.installArtifact(kernel);

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
}
