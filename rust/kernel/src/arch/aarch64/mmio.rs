use kernel::mmu::VirtualAddress;

// Volatile MMIO accessors. These are `unsafe` because the caller picks the
// address: a safe `VirtualAddress` can name anything, so soundness depends on
// the caller proving the address refers to a device register that tolerates the
// access width and side effects. Volatile prevents the compiler from eliding or
// reordering the access.

/// # Safety
/// `address` must refer to a 4-byte-aligned, currently mapped MMIO register
/// whose read has no side effects beyond the device's defined behavior.
pub unsafe fn read32(address: VirtualAddress) -> u32 {
    unsafe { core::ptr::read_volatile(address.get() as *const u32) }
}

/// # Safety
/// `address` must refer to a 4-byte-aligned, currently mapped MMIO register
/// that accepts a 32-bit write.
pub unsafe fn write32(address: VirtualAddress, value: u32) {
    unsafe { core::ptr::write_volatile(address.get() as *mut u32, value) };
}

/// # Safety
/// `address` must refer to a currently mapped MMIO register that accepts an
/// 8-bit write.
pub unsafe fn write8(address: VirtualAddress, value: u8) {
    unsafe { core::ptr::write_volatile(address.get() as *mut u8, value) };
}
