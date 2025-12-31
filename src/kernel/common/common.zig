//! Common kernel utilities shared between architectures.
//! Add new common modules here - no build.zig changes needed.

pub const trap = @import("trap.zig");
pub const mmu = @import("mmu.zig");

// Ensure tests from submodules are included
comptime {
    _ = trap;
    _ = mmu;
}
