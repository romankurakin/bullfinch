//! Volatile access to memory-mapped device registers.
//!
//! `VirtualAddress` alone does not prove that an address names a device register.
//! The caller must prove that the mapping, access width, and device side effects
//! permit the operation. Volatile keeps the compiler from removing the access
//! or reordering it across other externally observable events. Hardware ordering
//! still requires the appropriate barriers, and volatile access is not atomic.
//!
//! See `core::ptr::read_volatile` for Rust's volatile-access guarantees.

use kernel::mmu::VirtualAddress;

/// # Safety
/// `address` must refer to a 4-byte-aligned, currently mapped MMIO register
/// whose read has no side effects beyond the device's defined behavior.
pub unsafe fn read32(address: VirtualAddress) -> u32 {
    // SAFETY: The caller proves that `address` is a valid 32-bit MMIO register.
    unsafe { core::ptr::read_volatile(address.get() as *const u32) }
}

/// # Safety
/// `address` must refer to a 4-byte-aligned, currently mapped MMIO register
/// that accepts a 32-bit write.
pub unsafe fn write32(address: VirtualAddress, value: u32) {
    // SAFETY: The caller proves that `address` is a valid 32-bit MMIO register.
    unsafe { core::ptr::write_volatile(address.get() as *mut u32, value) };
}

/// # Safety
/// `address` must refer to a currently mapped MMIO register that accepts an
/// 8-bit write.
pub unsafe fn write8(address: VirtualAddress, value: u8) {
    // SAFETY: The caller proves that `address` is a valid 8-bit MMIO register.
    unsafe { core::ptr::write_volatile(address.get() as *mut u8, value) };
}
