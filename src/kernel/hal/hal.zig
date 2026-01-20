//! Hardware Abstraction Layer.
//!
//! The HAL bridges architecture-specific code into a uniform interface. Kernel code
//! imports hal for MMU, timer, console, and trap operations without caring whether
//! it's ARM64 or RISC-V underneath.
//!
//! Boot is two-phase because of the address space transition:
//!
//! Phase 1 (physical addresses):
//! - Init hardware (UART at physical address)
//! - Init trap vector (physical address, catches early crashes)
//! - Enable MMU (both identity and higher-half mappings active)
//! - Jump to higher-half
//!
//! Phase 2 (virtual addresses):
//! - Reinit trap vector (now uses virtual address)
//! - Switch UART to virtual address
//! - Remove identity mapping (no low-address access to kernel)
//!
//! This sequence allows the kernel to be linked at high addresses while booting
//! from physical addresses where the bootloader placed us.

const builtin = @import("builtin");
const std = @import("std");

const board = @import("board");
const boot_log = @import("../boot/log.zig");
const console = @import("../console/console.zig");
const fdt = @import("../fdt/fdt.zig");
const hwinfo = @import("../hwinfo/hwinfo.zig");
const memory = @import("../memory/memory.zig");
pub const cpu = @import("cpu.zig");
pub const interrupt = @import("interrupt.zig");
pub const timer = @import("timer.zig");

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

    const TrapFrame = arch.trap_frame.TrapFrame;
    if (!@hasDecl(TrapFrame, "FRAME_SIZE"))
        @compileError("TrapFrame must have FRAME_SIZE constant");
    if (TrapFrame.FRAME_SIZE != @sizeOf(TrapFrame))
        @compileError("TrapFrame.FRAME_SIZE must match @sizeOf(TrapFrame)");
    if (!@hasDecl(TrapFrame, "getReg"))
        @compileError("TrapFrame must have getReg function");
    if (TrapFrame.FRAME_SIZE & 0xF != 0)
        @compileError("TrapFrame.FRAME_SIZE must be 16-byte aligned");
    if (@alignOf(TrapFrame) < 8)
        @compileError("TrapFrame must be at least 8-byte aligned");
}

/// Physical-mode initialization. Called from boot.zig before jumping to higher-half.
/// Initializes console, traps, and MMU (with identity + higher-half mappings).
/// Returns to caller which then switches SP and jumps to kmain.
pub export fn physInit() void {
    console.init();
    console.print("\n");
    boot_log.header();
    boot_log.uart();

    // Install trap vectors early so MMU faults can be caught and debugged.
    // Uses PC-relative addressing, works at physical addresses.
    arch.trap.init();
    boot_log.trap();

    // Pass DTB pointer so MMU can map enough to cover it
    arch.mmu.init(board.KERNEL_PHYS_LOAD, boot.dtb_ptr);
    boot_log.mmu();
}

/// Kernel virtual base address, exported for boot.zig to use when jumping to higher-half.
pub export const KERNEL_VIRT_BASE: usize = arch.mmu.KERNEL_VIRT_BASE;

/// Get validated DTB handle. Returns null if DTB unavailable or invalid.
/// DTB is accessed via higher-half mapping of original bootloader location.
fn getDtb() ?fdt.Fdt {
    if (boot.dtb_ptr == 0) return null;
    const dtb: fdt.Fdt = @ptrFromInt(mmu.physToVirt(boot.dtb_ptr));
    fdt.checkHeader(dtb) catch return null;
    return dtb;
}

/// Finalizes address space transition and initializes timer hardware.
pub fn virtInit() void {
    // Reinit trap vector to virtual address, must happen before removing identity mapping
    arch.trap.init();

    // Arch-specific post-MMU fixups (RISC-V reloads GP register)
    arch.mmu.postMmuInit();

    // Switch console to virtual UART address (ARM64 only, RISC-V uses SBI)
    console.postMmuInit();

    const dtb = getDtb() orelse @panic("boot: DTB required for hardware discovery");
    hwinfo.init(boot.dtb_ptr, dtb);

    arch.mmu.expandPhysmap(hwinfo.info.total_memory);

    arch.mmu.removeIdentityMapping();
    boot_log.virt();

    // Initialize timer frequency (ARM64 reads register, RISC-V uses hwinfo value)
    timer.initFrequency(hwinfo.info.timer_frequency);
}
