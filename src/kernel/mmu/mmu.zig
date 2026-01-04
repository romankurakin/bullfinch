//! Common Paging Types.
//!
//! Shared definitions for ARM64 and RISC-V MMU code. Both architectures use 4KB
//! pages and 512-entry page tables (4KB = 512 × 8-byte PTEs). The actual page
//! table format and TLB operations are architecture-specific.

/// Page size constants (4KB pages on both ARM64 and RISC-V).
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

/// Permission flags for page mapping.
/// All valid mappings are implicitly readable. Global bit is set automatically.
pub const PageFlags = struct {
    write: bool = false,
    exec: bool = false,
    user: bool = false,
};

/// Errors that can occur during page mapping operations.
pub const MapError = error{
    /// Virtual or physical address not page-aligned
    NotAligned,
    /// Address is not in valid canonical range
    NotCanonical,
    /// Intermediate page table not present (caller must allocate)
    TableNotPresent,
    /// Entry already contains a valid mapping
    AlreadyMapped,
    /// Attempted to map over a superpage (1GB/2MB block)
    SuperpageConflict,
};

/// Errors that can occur during page unmapping operations.
pub const UnmapError = error{
    /// Address is not in valid canonical range
    NotCanonical,
    /// Page is not mapped
    NotMapped,
    /// Cannot unmap individual page from superpage
    SuperpageConflict,
};

test "PAGE_SIZE is 4KB" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 4096), PAGE_SIZE);
    try std.testing.expectEqual(@as(usize, 1) << PAGE_SHIFT, PAGE_SIZE);
}

test "ENTRIES_PER_TABLE fits one page" {
    const std = @import("std");
    try std.testing.expectEqual(PAGE_SIZE, ENTRIES_PER_TABLE * 8);
}
