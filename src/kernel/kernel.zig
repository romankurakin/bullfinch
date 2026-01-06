//! Kernel Module Root.
//!
//! Re-exports shared kernel subsystems.
//! Architecture-specific code imports kernel.zig to access common functionality.

pub const clock = @import("clock/clock.zig");
pub const console = @import("console/console.zig");
pub const debug = @import("debug/debug.zig");
pub const fdt = @import("fdt/fdt.zig");
pub const memory = @import("memory/memory.zig");
pub const mmu = @import("mmu/mmu.zig");
pub const pmm = @import("pmm/pmm.zig");
pub const trap = @import("trap/trap.zig");

comptime {
    _ = clock;
    _ = console;
    _ = debug;
    _ = fdt;
    _ = memory;
    _ = mmu;
    _ = pmm;
    _ = trap;
}
