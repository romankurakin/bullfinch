//! Memory and peripheral configuration for QEMU virt RISC-V.
//! Pure data - no imports, no dependencies.

pub const DRAM_BASE: usize = 0x8000_0000;
pub const KERNEL_PHYS_LOAD: usize = 0x8020_0000; // Above OpenSBI

// Kernel end from linker (at virtual address after linking)
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
