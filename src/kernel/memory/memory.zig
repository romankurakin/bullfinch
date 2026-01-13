//! Memory Constants.
//!
//! Shared memory layout constants used by PMM, MMU, VMM, and other subsystems.

const std = @import("std");

/// Page size in bytes (4KB on both ARM64 and RISC-V).
pub const PAGE_SIZE: usize = 4096;

/// Log2 of page size (for shifts instead of divides).
pub const PAGE_SHIFT: u6 = 12;

/// Number of entries per page table (512 for 4KB pages with 8-byte PTEs).
pub const ENTRIES_PER_TABLE: usize = 512;

/// Maximum expected DTB size for boot reservation (1MB).
/// Bootloaders typically place DTB near end of RAM; we reserve this much
/// to ensure metadata placement doesn't overwrite it.
pub const DTB_MAX_SIZE: usize = 1 << 20;

/// Minimum physmap size during early boot (1GB).
/// Ensures at least one gigapage is mapped before DTB parsing completes.
pub const MIN_PHYSMAP_SIZE: usize = 1 << 30;

comptime {
    if (PAGE_SIZE == 0 or (PAGE_SIZE & (PAGE_SIZE - 1)) != 0)
        @compileError("PAGE_SIZE must be a power of 2");
    if ((@as(usize, 1) << PAGE_SHIFT) != PAGE_SIZE)
        @compileError("PAGE_SHIFT must equal log2(PAGE_SIZE)");
    if (ENTRIES_PER_TABLE * 8 != PAGE_SIZE)
        @compileError("ENTRIES_PER_TABLE * 8 must equal PAGE_SIZE");
}

test "PAGE_SIZE is 4KB" {
    try std.testing.expectEqual(@as(usize, 4096), PAGE_SIZE);
    try std.testing.expectEqual(@as(usize, 1) << PAGE_SHIFT, PAGE_SIZE);
}

test "ENTRIES_PER_TABLE fits one page" {
    try std.testing.expectEqual(PAGE_SIZE, ENTRIES_PER_TABLE * 8);
}
