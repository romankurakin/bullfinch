//! Memory and peripheral configuration for QEMU virt RISC-V.

pub const DRAM_BASE: usize = 0x8000_0000;
pub const KERNEL_PHYS_LOAD: usize = 0x8020_0000; // Above OpenSBI
pub const TIMER_FREQ: u64 = 10_000_000;

// Kernel end from linker (at virtual address after linking)
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
