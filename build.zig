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

    const board_module_path = b.pathJoin(&.{ "src", "kernel", "arch", arch_dir, "boards", board, "board.zig" });
    // Board module provides HAL abstraction for the target platform.
    const board_module = b.createModule(.{
        .root_source_file = b.path(board_module_path),
        .target = target,
        .optimize = optimize,
    });

    // Conditionally import arch-specific modules to avoid unused dependencies.
    switch (target.result.cpu.arch) {
        .aarch64 => {
            const arm64_uart_module = b.createModule(.{
                .root_source_file = b.path("src/kernel/arch/arm64/uart.zig"),
                .target = target,
                .optimize = optimize,
            });
            board_module.addImport("arm64_uart", arm64_uart_module);
        },
        .riscv64 => {
            const riscv_uart_module = b.createModule(.{
                .root_source_file = b.path("src/kernel/arch/riscv64/uart.zig"),
                .target = target,
                .optimize = optimize,
            });
            board_module.addImport("riscv_uart", riscv_uart_module);
        },
        else => {},
    }
    kernel_module.addImport("board", board_module);

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

    const qemu_arm64 = b.addSystemCommand(&.{
        "qemu-system-aarch64", "-machine",   "virt",
        "-cpu",                "cortex-a76", "-m",
        "128M",                "-nographic", "-kernel",
    });
    qemu_arm64.addArtifactArg(kernel);
    b.step("qemu-arm64", "Run ARM64").dependOn(&qemu_arm64.step);

    const qemu_riscv = b.addSystemCommand(&.{
        "qemu-system-riscv64", "-machine", "virt",
        "-m",                  "128M",     "-nographic",
        "-bios",               "default",  "-kernel",
    });
    qemu_riscv.addArtifactArg(kernel);
    b.step("qemu-riscv64", "Run RISC-V").dependOn(&qemu_riscv.step);

    const test_step = b.step("test", "Run all tests");

    // Run centralized test suite through kernel root that imports all modules with inline tests
    var kernel_tests: *std.Build.Step.Run = undefined;
    if (test_filter) |filter| {
        kernel_tests = b.addSystemCommand(&.{ "zig", "test", "src/kernel/root_test.zig", "--test-filter", filter });
    } else {
        kernel_tests = b.addSystemCommand(&.{ "zig", "test", "src/kernel/root_test.zig" });
    }
    test_step.dependOn(&kernel_tests.step);
}
