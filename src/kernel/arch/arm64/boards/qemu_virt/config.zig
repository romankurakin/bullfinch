//! Memory and peripheral configuration for QEMU virt ARM64.

pub const DRAM_BASE: usize = 0x4000_0000;
/// Kernel load address (after DTB area).
pub const KERNEL_PHYS_LOAD: usize = 0x4020_0000;
pub const TIMER_FREQ: u64 = 62_500_000;
pub const UART_PHYS: usize = 0x0900_0000;

// GIC interrupt controller version is configurable (v2 or v3).
pub const GIC_VERSION: u8 = 3;
pub const GICD_BASE: usize = 0x0800_0000; // Distributor (both versions)
pub const GICC_BASE: usize = 0x0801_0000; // CPU Interface (GICv2 only)
pub const GICR_BASE: usize = 0x080A_0000; // Redistributor (GICv3 only)

// Kernel end from linker (at virtual address after linking)
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
