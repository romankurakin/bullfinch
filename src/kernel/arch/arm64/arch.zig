//! ARM64 architecture module.

const board = @import("board");

// Validate required board config
comptime {
    if (!@hasDecl(board.config, "UART_PHYS"))
        @compileError("ARM64 board config must define UART_PHYS");
    if (!@hasDecl(board.config, "KERNEL_PHYS_LOAD"))
        @compileError("ARM64 board config must define KERNEL_PHYS_LOAD");
}

pub const boot = @import("boot.zig");
pub const mmu = @import("mmu.zig");
pub const timer = @import("timer.zig");
pub const trap = @import("trap.zig");
pub const uart = @import("uart.zig");
