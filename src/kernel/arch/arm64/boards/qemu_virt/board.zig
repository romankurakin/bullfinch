//! Board-specific configuration for QEMU virt ARM64.

/// Kernel load address. QEMU with raw binary loads at RAM base (0x40000000).
/// DTB is placed elsewhere in RAM and its address is passed in x0.
pub const KERNEL_PHYS_LOAD: usize = 0x4000_0000;

/// UART base address for early boot console.
pub const UART_PHYS: usize = 0x0900_0000;

// Kernel end from linker (at virtual address after linking)
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
