//! Memory and peripheral configuration for QEMU virt RISC-V.

/// Base physical address of DRAM. QEMU virt places RAM at 0x8000_0000.
pub const DRAM_BASE: usize = 0x8000_0000;

/// Kernel load address. Placed at DRAM_BASE + 2MB to leave room for
/// OpenSBI firmware which occupies the first 2MB of DRAM.
pub const KERNEL_PHYS_LOAD: usize = 0x8020_0000;

/// Linker-provided symbol marking the end of the kernel image.
/// Address is virtual after MMU is enabled.
extern const __kernel_end: u8;

/// Returns the virtual address of the kernel image end.
pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}
