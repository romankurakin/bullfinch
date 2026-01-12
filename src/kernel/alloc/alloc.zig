//! Kernel Object Allocators.
//!
//! Provides fixed-size pool allocation for kernel objects (threads, handles,
//! VMOs, channels). Uses bitmap-based free tracking for O(1) allocation.
//! Backed by physical pages from PMM.

const pool = @import("pool.zig");

pub const Pool = pool.Pool;

comptime {
    _ = pool;
}
