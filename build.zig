const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const board = b.option([]const u8, "board", "Target board") orelse "qemu_virt";

    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name") orelse null;

    const arch_dir = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .riscv64 => "riscv64",
        else => @panic("Unsupported architecture"),
    };

    if (!std.mem.eql(u8, board, "qemu_virt")) {
        @panic("Unsupported board");
    }

    // Create kernel module from main.zig for architecture-independent code.
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Board config - pure data, no dependencies. Breaks circular deps.
    const config_module_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "boards", board, "config.zig" });
    const config_module = b.createModule(.{
        .root_source_file = b.path(config_module_path),
        .target = target,
        .optimize = optimize,
    });

    const board_module_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "boards", board, "board.zig" });
    // Board module provides HAL abstraction for the target platform.
    const board_module = b.createModule(.{
        .root_source_file = b.path(board_module_path),
        .target = target,
        .optimize = optimize,
    });

    // Common kernel utilities (pure functions, no dependencies).
    // Add new common modules to common.zig - no build.zig changes needed.
    const common_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/common/common.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Arch module re-exports all arch-specific code.
    // Add new arch modules to arch.zig - no build.zig changes needed.
    const arch_module_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "arch.zig" });
    const arch_module = b.createModule(.{
        .root_source_file = b.path(arch_module_path),
        .target = target,
        .optimize = optimize,
    });

    // Unified HAL combines arch and board into single interface for kernel.
    const hal_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/hal.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Wire up module dependencies (no circular deps).
    // config -> (nothing, pure data)
    // common -> (nothing, pure functions)
    // arch -> config, common
    // board -> arch (for uart driver), config
    // hal -> arch, board (injects board.hal.print into arch.trap at runtime)
    // kernel -> hal
    arch_module.addImport("common", common_module);
    arch_module.addImport("config", config_module);
    board_module.addImport("arch", arch_module);
    board_module.addImport("config", config_module);
    hal_module.addImport("arch", arch_module);
    hal_module.addImport("board", board_module);
    kernel_module.addImport("hal", hal_module);

    const kernel_name = switch (target.result.cpu.arch) {
        .aarch64 => "kernel-arm64",
        .riscv64 => "kernel-riscv64",
        else => "kernel",
    };

    const kernel = b.addExecutable(.{
        .name = kernel_name,
        .root_module = kernel_module,
    });

    // Custom linker script defines memory layout, stack, BSS, and entry point.
    const linker_script_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "boards", board, "kernel.ld" });
    kernel.setLinkerScript(b.path(linker_script_path));
    if (target.result.cpu.arch == .riscv64) {
        // RISC-V kernels typically run at high addresses (≥0x8000_0000), which
        // exceeds medlow's ±2GB range from PC. When linking compiler_rt and other
        // runtime code, HI20 relocations can overflow if symbols are far apart.
        // Medium model allows PC-relative addressing across the full address space.
        kernel.root_module.code_model = .medium;
    }

    b.installArtifact(kernel);

    const test_step = b.step("test", "Run all tests");

    // Native target for running tests on host (not the cross-compile target)
    const native_target = b.resolveTargetQuery(.{});

    // Test module for common utilities (shared between architectures).
    const test_common_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/common/common.zig"),
        .target = native_target,
    });

    // Create test root module with common dependency
    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/root_test.zig"),
        .target = native_target,
    });
    test_root_module.addImport("common", test_common_module);

    // Run centralized test suite through kernel root that imports all modules with inline tests.
    // Uses native target for host testing.
    const kernel_tests = b.addTest(.{
        .root_module = test_root_module,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_tests = b.addRunArtifact(kernel_tests);
    test_step.dependOn(&run_tests.step);
}
