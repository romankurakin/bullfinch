//! Boot Initialization.
//!
//! Orchestrates the two-phase boot sequence for the kernel. Phase 1 runs at
//! physical addresses before MMU, phase 2 runs at virtual addresses after.
//!
//! Phase 1 (physInit, physical addresses):
//! - Init console (UART at physical address)
//! - Init trap vector (catches early faults)
//! - Enable MMU (identity + higher-half mappings)
//! - Return to boot.zig which jumps to higher-half
//!
//! Phase 2 (virtInit, virtual addresses):
//! - Reinit trap vector at virtual address
//! - Switch console to virtual UART
//! - Parse DTB for hardware info
//! - Expand physmap, remove identity mapping
//! - Init timer frequency

const board = @import("board");
const boot_log = @import("log.zig");
const console = @import("../console/console.zig");
const fdt = @import("../fdt/fdt.zig");
const hal = @import("../hal/hal.zig");
const hwinfo = @import("../hwinfo/hwinfo.zig");

const panic_msg = struct {
    const DTB_REQUIRED = "boot: DTB required for hardware discovery";
};

/// Kernel virtual base address, exported for boot.zig assembly.
pub export const KERNEL_VIRT_BASE: usize = hal.mmu.KERNEL_VIRT_BASE;

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
    hal.trap.init();
    boot_log.trap();

    // Pass DTB pointer so MMU can map enough to cover it
    hal.mmu.init(board.KERNEL_PHYS_LOAD, hal.boot.dtb_ptr);
    boot_log.mmu();
}

/// Finalizes address space transition and initializes timer hardware.
pub fn virtInit() void {
    // Reinit trap vector to virtual address, must happen before removing identity mapping
    hal.trap.init();

    // Arch-specific post-MMU fixups (RISC-V reloads GP register)
    hal.mmu.postMmuInit();

    // Switch console to virtual UART address (ARM64 only, RISC-V uses SBI)
    console.postMmuInit();

    const dtb = getDtb() orelse @panic(panic_msg.DTB_REQUIRED);
    hwinfo.init(hal.boot.dtb_ptr, dtb);

    hal.mmu.expandPhysmap(hwinfo.info.total_memory);

    hal.mmu.removeIdentityMapping();
    boot_log.virt();

    // Initialize timer frequency (ARM64 reads register, RISC-V uses hwinfo value)
    hal.timer.initFrequency(hwinfo.info.timer_frequency);
}

/// Get validated DTB handle. Returns null if DTB unavailable or invalid.
/// DTB is accessed via higher-half mapping of original bootloader location.
fn getDtb() ?fdt.Fdt {
    if (hal.boot.dtb_ptr == 0) return null;
    const dtb: fdt.Fdt = @ptrFromInt(hal.mmu.physToVirt(hal.boot.dtb_ptr));
    fdt.checkHeader(dtb) catch return null;
    return dtb;
}
