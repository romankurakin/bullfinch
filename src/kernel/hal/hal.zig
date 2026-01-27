//! Hardware Abstraction Layer.
//!
//! Bridges architecture-specific code into a uniform interface. Kernel code
//! imports hal for MMU, timer, console, and trap operations without caring
//! whether it's ARM64 or RISC-V underneath.

const builtin = @import("builtin");
const std = @import("std");

const board = @import("board");
const memory = @import("../memory/memory.zig");

pub const cpu = @import("cpu.zig");
pub const entropy = @import("entropy.zig");
pub const interrupt = @import("interrupt.zig");
pub const timer = @import("timer.zig");
pub const trap_frame = @import("trap_frame.zig");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/arch.zig"),
    .riscv64 => @import("../arch/riscv64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const boot = arch.boot;
pub const mmu = arch.mmu;
pub const trap = arch.trap;

/// Kernel physical memory range (load address to end of image).
pub fn getKernelPhysRange() struct { start: usize, end: usize } {
    return .{
        .start = board.KERNEL_PHYS_LOAD,
        .end = mmu.virtToPhys(board.kernelEnd()),
    };
}

comptime {
    const virt_base = arch.mmu.KERNEL_VIRT_BASE;
    const PAGE_SIZE = memory.PAGE_SIZE;
    const PAGE_SHIFT = memory.PAGE_SHIFT;
    const GB: usize = 1 << 30;

    if (virt_base & (GB - 1) != 0)
        @compileError("KERNEL_VIRT_BASE must be 1GB aligned");
    if (virt_base < (1 << 63))
        @compileError("KERNEL_VIRT_BASE must be in upper address space");
    if (@popCount(PAGE_SIZE) != 1)
        @compileError("PAGE_SIZE must be a power of 2");
    if (std.math.log2_int(usize, PAGE_SIZE) != PAGE_SHIFT)
        @compileError("PAGE_SHIFT doesn't match PAGE_SIZE");
    if (@hasDecl(board, "KERNEL_PHYS_LOAD")) {
        if (board.KERNEL_PHYS_LOAD & (PAGE_SIZE - 1) != 0)
            @compileError("KERNEL_PHYS_LOAD must be page-aligned");
    }

    // TrapFrame checks are in hal/trap_frame.zig
    _ = trap_frame;
}
