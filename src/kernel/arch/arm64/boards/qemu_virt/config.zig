//! Memory and peripheral configuration for QEMU virt ARM64.
//! Pure data - no imports, no dependencies.

pub const UART_PHYS: usize = 0x0900_0000;
pub const DRAM_BASE: usize = 0x4000_0000;
pub const KERNEL_PHYS_LOAD: usize = 0x4008_0000;

// Kernel end from linker (at virtual address after linking)
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
