//! Board-specific operations for QEMU virt RISC-V.
//! Imports config (pure data) and arch.uart (SBI console).

pub const config = @import("config.zig");
const uart = @import("../../uart.zig");

/// Board-level HAL - UART operations (via SBI).
pub const hal = struct {
    pub fn init() void {
        uart.init();
    }

    pub fn print(s: []const u8) void {
        uart.print(s);
    }

    /// No-op - SBI console doesn't need address translation.
    pub fn setUartBase(_: usize) void {}
};
