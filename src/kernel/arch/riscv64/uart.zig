//! RISC-V UART via SBI.
//!
//! Unlike ARM where we directly program PL011, RISC-V uses SBI's legacy console for
//! early boot output. OpenSBI handles the actual UART programming. Eventually this
//! moves to userspace with direct MMIO access.

const sbi = @import("sbi.zig");

/// Initialize UART. No-op since SBI handles console setup.
pub fn init() void {}

/// Post-MMU transition. No-op since SBI handles addressing.
pub fn postMmuInit() void {}

/// Print string to console via SBI firmware.
pub fn print(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') {
            sbi.legacyConsolePutchar('\r');
        }
        sbi.legacyConsolePutchar(byte);
    }
}
