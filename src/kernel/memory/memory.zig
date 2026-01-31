//! Memory Constants.
//!
//! Shared memory layout constants used across kernel subsystems.

const std = @import("std");

/// Page size in bytes (4KB on both ARM64 and RISC-V).
pub const PAGE_SIZE: usize = 4096;

/// Guard page size (one page, unmapped to catch stack overflow).
pub const GUARD_SIZE: usize = PAGE_SIZE;

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

/// Kernel stack slot size (guard page + stack pages).
/// Each thread gets one slot in the kernel stack virtual region.
/// Guard page is unmapped; only stack pages are backed by physical memory.
pub const KSTACK_SLOT_SIZE: usize = GUARD_SIZE + (PAGE_SIZE * 2); // 4KB guard + 8KB stack

comptime {
    if (PAGE_SIZE == 0 or (PAGE_SIZE & (PAGE_SIZE - 1)) != 0)
        @compileError("PAGE_SIZE must be a power of 2");
    if ((@as(usize, 1) << PAGE_SHIFT) != PAGE_SIZE)
        @compileError("PAGE_SHIFT must equal log2(PAGE_SIZE)");
    if (ENTRIES_PER_TABLE * 8 != PAGE_SIZE)
        @compileError("ENTRIES_PER_TABLE * 8 must equal PAGE_SIZE");
}

test "sets PAGE_SIZE to 4KB" {
    try std.testing.expectEqual(@as(usize, 4096), PAGE_SIZE);
    try std.testing.expectEqual(@as(usize, 1) << PAGE_SHIFT, PAGE_SIZE);
}

test "fits ENTRIES_PER_TABLE in one page" {
    try std.testing.expectEqual(PAGE_SIZE, ENTRIES_PER_TABLE * 8);
}
