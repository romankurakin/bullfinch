//! Kernel Allocators.
//!
//! Module root for kernel allocation APIs.

const kmalloc = @import("kmalloc.zig");
const slab = @import("slab.zig");

pub const Pool = slab.Pool;
pub const FreeError = slab.FreeError;
pub const AllocError = kmalloc.AllocError;
pub const init = kmalloc.init;
pub const alloc = kmalloc.alloc;
pub const free = kmalloc.free;

comptime {
    _ = slab;
    _ = kmalloc;
}
