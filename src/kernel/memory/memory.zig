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

test "PAGE_SIZE is 4KB" {
    try std.testing.expectEqual(@as(usize, 4096), PAGE_SIZE);
    try std.testing.expectEqual(@as(usize, 1) << PAGE_SHIFT, PAGE_SIZE);
}

test "ENTRIES_PER_TABLE fits one page" {
    try std.testing.expectEqual(PAGE_SIZE, ENTRIES_PER_TABLE * 8);
}
