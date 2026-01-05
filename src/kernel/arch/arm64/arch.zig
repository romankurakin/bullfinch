//! ARM64 architecture module.

const board = @import("board");

// Validate required board config
comptime {
    if (!@hasDecl(board, "UART_PHYS"))
        @compileError("ARM64 board must define UART_PHYS");
    if (!@hasDecl(board, "KERNEL_PHYS_LOAD"))
        @compileError("ARM64 board must define KERNEL_PHYS_LOAD");
}

pub const boot = @import("boot.zig");
pub const mmu = @import("mmu.zig");
pub const timer = @import("timer.zig");
pub const trap = @import("trap.zig");
pub const uart = @import("uart.zig");
