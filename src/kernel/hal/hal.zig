//! Unified Hardware Abstraction Layer.
//!
//! Combines architecture-specific and board-specific operations into a single interface.
//! Kernel code imports only this module for all hardware operations.
//!
//! Boot sequence has strict ordering due to address space transitions:
//!   1. Hardware init (UART at physical address)
//!   2. MMU enable (identity + higher-half mappings active)
//!   3. Trap init (vector table at higher-half address)
//!   4. Jump to higher-half
//!   5. Switch UART to virtual address
//!   6. Remove identity mapping
//!
//! Order is enforced by `bootPhysical()` and `bootVirtual()` structure.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("../kernel.zig").console;

// Select arch and board based on target architecture.
// This eliminates need for build.zig module wiring.
const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/arch.zig"),
    .riscv64 => @import("../arch/riscv64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

const board = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/boards/qemu_virt/board.zig"),
    .riscv64 => @import("../arch/riscv64/boards/qemu_virt/board.zig"),
    else => @compileError("Unsupported architecture"),
};

// Compile-time verifications.
comptime {
    const KERNEL_VIRT_BASE = arch.mmu.KERNEL_VIRT_BASE;
    const PAGE_SIZE = arch.mmu.PAGE_SIZE;
    const PAGE_SHIFT = arch.mmu.PAGE_SHIFT;
    const GB: usize = 1 << 30;

    // Kernel virtual base must be gigabyte-aligned (for 1GB block mappings)
    if (KERNEL_VIRT_BASE & (GB - 1) != 0) {
        @compileError("KERNEL_VIRT_BASE must be 1GB aligned");
    }

    // Kernel virtual base must be in upper half (high bit set)
    if (KERNEL_VIRT_BASE < (1 << 63)) {
        @compileError("KERNEL_VIRT_BASE must be in upper address space");
    }

    // Page size must be power of 2
    if (@popCount(PAGE_SIZE) != 1) {
        @compileError("PAGE_SIZE must be a power of 2");
    }

    // PAGE_SHIFT must match PAGE_SIZE
    if (std.math.log2_int(usize, PAGE_SIZE) != PAGE_SHIFT) {
        @compileError("PAGE_SHIFT doesn't match PAGE_SIZE");
    }

    // Verify kernel physical base if defined
    if (@hasDecl(board.config, "KERNEL_PHYS_LOAD")) {
        const KERNEL_PHYS_LOAD = board.config.KERNEL_PHYS_LOAD;

        // Kernel must be page-aligned
        if (KERNEL_PHYS_LOAD & (PAGE_SIZE - 1) != 0) {
            @compileError("KERNEL_PHYS_LOAD must be page-aligned");
        }
    }

    // Verify trap context structure
    const TrapContext = arch.trap.TrapContext;

    // TrapContext must have FRAME_SIZE constant matching actual size
    if (!@hasDecl(TrapContext, "FRAME_SIZE")) {
        @compileError("TrapContext must have FRAME_SIZE constant");
    }
    if (TrapContext.FRAME_SIZE != @sizeOf(TrapContext)) {
        @compileError("TrapContext.FRAME_SIZE must match @sizeOf(TrapContext)");
    }

    // TrapContext must have getReg for register access
    if (!@hasDecl(TrapContext, "getReg")) {
        @compileError("TrapContext must have getReg function");
    }

    // Frame size must be 16-byte aligned
    if (TrapContext.FRAME_SIZE & 0xF != 0) {
        @compileError("TrapContext.FRAME_SIZE must be 16-byte aligned");
    }

    // Struct must be at least 8-byte aligned (for u64 register storage)
    if (@alignOf(TrapContext) < 8) {
        @compileError("TrapContext must be at least 8-byte aligned");
    }
}

pub const boot = arch.boot;
pub const trap = arch.trap;
pub const mmu = arch.mmu;
pub const config = board.config;

/// Runs at physical addresses. Initializes hardware, MMU, traps, then jumps to higher-half.
/// The continuation should call `bootVirtual()` first.
pub fn bootPhysical(continuation: *const fn (usize) noreturn, arg: usize) noreturn {
    console.init();
    print("\nHardware initialized\n");

    arch.hal.initMmu(board.config.KERNEL_PHYS_LOAD);
    print("MMU enabled\n");

    arch.hal.initTrap();
    print("Trap handling initialized\n");

    arch.hal.jumpToHigherHalf(continuation, arg);
}

/// Runs at virtual addresses. Finalizes address space transition.
/// Must be called first in the continuation.
pub fn bootVirtual() void {
    print("Running in higher-half virtual address space\n");

    if (@hasDecl(board.config, "UART_PHYS")) {
        console.setBase(arch.hal.physToVirt(board.config.UART_PHYS));
    }

    arch.hal.removeIdentityMapping();
    print("Identity mapping removed\n");
}

pub fn print(s: []const u8) void {
    console.print(s);
}

pub fn halt() noreturn {
    arch.hal.halt();
}

/// Flush all TLB entries.
pub fn flushTlb() void {
    arch.hal.flushTlb();
}

/// Flush TLB for a specific virtual address.
pub fn flushTlbAddr(vaddr: usize) void {
    arch.hal.flushTlbAddr(vaddr);
}

/// Get kernel virtual base address.
pub fn kernelVirtBase() usize {
    return arch.hal.kernelVirtBase();
}

/// Convert physical address to kernel virtual address.
pub fn physToVirt(paddr: usize) usize {
    return arch.hal.physToVirt(paddr);
}

/// Convert kernel virtual address to physical address.
pub fn virtToPhys(vaddr: usize) usize {
    return arch.hal.virtToPhys(vaddr);
}
