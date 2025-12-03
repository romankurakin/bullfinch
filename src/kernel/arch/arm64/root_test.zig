//! ARM64 architecture root - imports all ARM64 modules for testing.

const uart = @import("uart.zig");
// trap.zig: excluded (ELF linksection incompatible with macOS)

comptime {
    _ = uart;
}
