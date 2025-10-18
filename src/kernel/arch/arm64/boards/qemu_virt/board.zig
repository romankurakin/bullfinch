//! Board description for QEMU's "virt" machine on ARM64.

pub const arm64 = struct {
    // PL011 UART MMIO base address for QEMU virt. Direct hardware access.
    pub const uart_base: usize = 0x0900_0000;
};

// HAL for ARM64. Provides uniform init/print interface.
pub const hal = struct {
    const pl011 = @import("arm64_uart");
    var state = pl011.State{};

    pub fn init() void {
        pl011.initDefault(arm64.uart_base, &state);
    }

    pub fn print(s: []const u8) void {
        pl011.print(arm64.uart_base, &state, s);
    }
};