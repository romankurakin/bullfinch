//! Kernel Module Root.
//!
//! Re-exports shared kernel subsystems.
//! Architecture-specific code imports kernel.zig to access common functionality.

pub const clock = @import("clock/clock.zig");
pub const console = @import("console/console.zig");
pub const mmu = @import("mmu/mmu.zig");
pub const trap = @import("trap/trap.zig");

comptime {
    _ = clock;
    _ = console;
    _ = mmu;
    _ = trap;
}
