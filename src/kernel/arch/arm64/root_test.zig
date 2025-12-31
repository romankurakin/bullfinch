//! ARM64 architecture root - imports all ARM64 modules for testing.

const uart = @import("uart.zig");
const mmu = @import("mmu.zig");
// trap.zig: excluded (ELF linksection incompatible with macOS test runner)

comptime {
    _ = uart;
    _ = mmu;
}
