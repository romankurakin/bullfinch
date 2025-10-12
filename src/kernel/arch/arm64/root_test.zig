//! ARM64 architecture root - imports all ARM64 modules for testing.

const uart = @import("uart.zig");

// Ensure all ARM64 modules are imported so their inline tests run
comptime {
    _ = uart;
}
