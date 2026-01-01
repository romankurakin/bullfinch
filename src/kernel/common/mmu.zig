//! Common MMU types shared between architectures.
//! Architecture-specific implementations import these for consistency.

/// Page size constants (4KB pages on both ARM64 and RISC-V).
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

/// Permission flags for page mapping.
/// All valid mappings are implicitly readable on both architectures.
/// Global bit is set automatically: kernel pages are global, user pages are not.
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
    // 512 entries * 8 bytes = 4096 bytes = one page
    try std.testing.expectEqual(PAGE_SIZE, ENTRIES_PER_TABLE * 8);
}
