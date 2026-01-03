//! Kernel module root - re-exports shared subsystems.

pub const console = @import("console/console.zig");
pub const mmu = @import("mmu/mmu.zig");
pub const trap = @import("trap/trap.zig");

// Ensure tests from submodules are included
comptime {
    _ = console;
    _ = mmu;
    _ = trap;
}
