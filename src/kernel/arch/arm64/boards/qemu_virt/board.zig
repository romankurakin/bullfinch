//! Board-specific operations for QEMU virt ARM64.

pub const config = @import("config");
const uart = @import("arch").uart;

/// Board-level HAL - UART operations.
pub const hal = struct {
    var uart_base: usize = config.UART_PHYS;

    pub fn init() void {
        uart.initDefault(uart_base);
    }

    pub fn print(s: []const u8) void {
        uart.print(uart_base, s);
    }

    pub fn setUartBase(addr: usize) void {
        uart_base = addr;
    }
};
