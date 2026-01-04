//! GIC (Generic Interrupt Controller) Dispatcher.
//!
//! ARM systems use the GIC to route hardware interrupts to CPU cores. GICv2 uses
//! memory-mapped registers for everything, while GICv3 moves the CPU interface to
//! system registers for lower latency.
//!
//! This module selects the appropriate implementation based on board config.

const board = @import("board");

const impl = switch (board.config.GIC_VERSION) {
    2 => @import("gicv2.zig"),
    3 => @import("gicv3.zig"),
    else => @compileError("Unsupported GIC version - must be 2 or 3"),
};

pub const init = impl.init;
pub const enableTimerInterrupt = impl.enableTimerInterrupt;
pub const acknowledge = impl.acknowledge;
pub const endOfInterrupt = impl.endOfInterrupt;
