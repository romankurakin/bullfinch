//! RISC-V UART via SBI firmware console (no direct MMIO).

const sbi = @import("sbi.zig");

pub fn init() void {} // SBI console needs no kernel setup

pub fn print(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') {
            sbi.legacyConsolePutchar('\r');
        }
        sbi.legacyConsolePutchar(byte);
    }
}
