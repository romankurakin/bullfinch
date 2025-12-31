//! RISC-V UART via SBI firmware console (no direct MMIO).

const sbi = @import("sbi.zig");

/// Initialize UART. No-op on RISC-V since SBI handles console setup.
pub fn init() void {}

/// Print string to console via SBI firmware.
pub fn print(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') {
            sbi.legacyConsolePutchar('\r');
        }
        sbi.legacyConsolePutchar(byte);
    }
}
