//! Board description for QEMU's "virt" machine on RISC-V.

pub const riscv64 = struct {
    pub const uart_base: ?usize = null; // SBI firmware console (no kernel MMIO)
};

pub const hal = struct {
    const sbi_uart = @import("riscv_uart");

    pub fn init() void {
        sbi_uart.init();
    }

    pub fn print(s: []const u8) void {
        sbi_uart.print(s);
    }
};