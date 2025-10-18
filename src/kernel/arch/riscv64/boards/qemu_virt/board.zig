//! Board description for QEMU's "virt" machine on RISC-V.

pub const riscv64 = struct {
    // RISC-V uses SBI firmware for console; no kernel MMIO needed for isolation.
    pub const uart_base: ?usize = null;
};

// HAL for RISC-V. Provides uniform init/print interface.
pub const hal = struct {
    const sbi_uart = @import("riscv_uart");

    pub fn init() void {
        sbi_uart.init();
    }

    pub fn print(s: []const u8) void {
        sbi_uart.print(s);
    }
};