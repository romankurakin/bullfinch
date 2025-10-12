//! UART abstraction for RISC-V using SBI firmware console.
//! Delegates to OpenSBI for output, avoiding direct MMIO in kernel.

const sbi = @import("sbi.zig");

// Stub init for HAL symmetry. SBI console doesn't need kernel setup.
pub fn init() void {}

// Print via SBI legacy console. Firmware handles UART, kernel stays isolated.
// Loops byte-by-byte; SBI may buffer or drop if host can't keep up.
pub fn print(s: []const u8) void {
    for (s) |byte| {
        sbi.legacyConsolePutchar(byte); // SBI call ensures privilege separation
    }
}
