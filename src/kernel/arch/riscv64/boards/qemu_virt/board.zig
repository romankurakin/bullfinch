//! Board-specific configuration for QEMU virt RISC-V.

/// Kernel load address. Placed 2MB into DRAM to leave room for
/// OpenSBI firmware which occupies the first 2MB.
pub const KERNEL_PHYS_LOAD: usize = 0x8020_0000;

/// Linker-provided symbol marking the end of the kernel image.
/// Address is virtual after MMU is enabled.
extern const __kernel_end: u8;

/// Returns the virtual address of the kernel image end.
pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
