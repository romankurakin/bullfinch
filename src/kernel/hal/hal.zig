//! Hardware Abstraction Layer.
//!
//! The HAL bridges architecture-specific code into a uniform interface. Kernel code
//! imports hal for MMU, timer, console, and trap operations without caring whether
//! it's ARM64 or RISC-V underneath.
//!
//! Boot is two-phase because of the address space transition:
//!
//!   Phase 1 (physical addresses):
//!     - Init hardware (UART at physical address)
//!     - Enable MMU (both identity and higher-half mappings active)
//!     - Init trap vector (physical address, catches early crashes)
//!     - Jump to higher-half
//!
//!   Phase 2 (virtual addresses):
//!     - Reinit trap vector (now uses virtual address)
//!     - Switch UART to virtual address
//!     - Remove identity mapping (security: no low-address access to kernel)
//!
//! This sequence allows the kernel to be linked at high addresses while booting
//! from physical addresses where the bootloader placed us.

const builtin = @import("builtin");
const std = @import("std");

const board = @import("board");
pub const console = @import("../kernel.zig").console;

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/arch.zig"),
    .riscv64 => @import("../arch/riscv64/arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const boot = arch.boot;
pub const config = board.config;
pub const mmu = arch.mmu;
pub const timer = @import("timer.zig");
pub const trap = arch.trap;

pub const disableInterrupts = arch.trap.disableInterrupts;
pub const flushTlb = arch.mmu.Tlb.flushAll;
pub const flushTlbAddr = arch.mmu.Tlb.flushAddr;
pub const halt = arch.trap.halt;
pub const physToVirt = arch.mmu.physToVirt;
pub const virtToPhys = arch.mmu.virtToPhys;
pub const waitForInterrupt = arch.trap.waitForInterrupt;

comptime {
    const KERNEL_VIRT_BASE = arch.mmu.KERNEL_VIRT_BASE;
    const PAGE_SIZE = arch.mmu.PAGE_SIZE;
    const PAGE_SHIFT = arch.mmu.PAGE_SHIFT;
    const GB: usize = 1 << 30;

    if (KERNEL_VIRT_BASE & (GB - 1) != 0)
        @compileError("KERNEL_VIRT_BASE must be 1GB aligned");
    if (KERNEL_VIRT_BASE < (1 << 63))
        @compileError("KERNEL_VIRT_BASE must be in upper address space");
    if (@popCount(PAGE_SIZE) != 1)
        @compileError("PAGE_SIZE must be a power of 2");
    if (std.math.log2_int(usize, PAGE_SIZE) != PAGE_SHIFT)
        @compileError("PAGE_SHIFT doesn't match PAGE_SIZE");
    if (@hasDecl(board.config, "KERNEL_PHYS_LOAD")) {
        if (board.config.KERNEL_PHYS_LOAD & (PAGE_SIZE - 1) != 0)
            @compileError("KERNEL_PHYS_LOAD must be page-aligned");
    }

    const TrapContext = arch.trap.TrapContext;
    if (!@hasDecl(TrapContext, "FRAME_SIZE"))
        @compileError("TrapContext must have FRAME_SIZE constant");
    if (TrapContext.FRAME_SIZE != @sizeOf(TrapContext))
        @compileError("TrapContext.FRAME_SIZE must match @sizeOf(TrapContext)");
    if (!@hasDecl(TrapContext, "getReg"))
        @compileError("TrapContext must have getReg function");
    if (TrapContext.FRAME_SIZE & 0xF != 0)
        @compileError("TrapContext.FRAME_SIZE must be 16-byte aligned");
    if (@alignOf(TrapContext) < 8)
        @compileError("TrapContext must be at least 8-byte aligned");
}

/// Runs at physical addresses. Initializes hardware, MMU, traps, then jumps to higher-half.
pub fn bootPhysical(continuation: *const fn (usize) noreturn, arg: usize) noreturn {
    console.init();
    console.print("\nHardware initialized\n");

    arch.mmu.init(board.config.KERNEL_PHYS_LOAD);
    console.print("MMU enabled\n");

    arch.trap.init();
    console.print("Trap handling initialized\n");

    arch.mmu.jumpToHigherHalf(continuation, arg);
}

/// Runs at virtual addresses. Finalizes address space transition.
pub fn bootVirtual() void {
    console.print("Running in higher-half virtual address space\n");

    // Reinit trap vector to virtual address
    arch.trap.init();

    if (@hasDecl(board.config, "UART_PHYS")) {
        console.setBase(arch.mmu.physToVirt(board.config.UART_PHYS));
    }

    arch.mmu.removeIdentityMapping();
    console.print("Identity mapping removed\n");
}
