//! Common MMU Types.
//!
//! Shared types for page table operations. Architecture-specific MMU
//! implementations are in arch/*/mmu.zig.

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
    /// Page allocator returned null (out of memory)
    OutOfMemory,
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
