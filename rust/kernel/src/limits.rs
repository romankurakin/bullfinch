//! Kernel capacity limits.
//!
//! Early boot uses static data structures. These bounds keep them fixed-size.

pub const MAX_MEMORY_ARENAS: usize = 4;
pub const MAX_RESERVED_REGIONS: usize = 8;
pub const MAX_TASKS: usize = 32;

pub const ENTRIES_PER_PAGE_TABLE: usize = 512;
pub const DEVICE_TREE_BLOB_MAX_SIZE: usize = 1 << 20;
pub const MINIMUM_PHYSMAP_SIZE: usize = 1 << 30;
