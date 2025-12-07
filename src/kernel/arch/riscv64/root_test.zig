//! RISC-V architecture root - imports all RISC-V modules for testing.

const uart = @import("uart.zig");
const sbi = @import("sbi.zig");
// trap.zig: excluded (ELF linksection incompatible with macOS test runner)

comptime {
    _ = uart;
    _ = sbi;
}
