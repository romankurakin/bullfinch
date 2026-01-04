//! RISC-V architecture root - imports all RISC-V modules for testing.

const mmu = @import("mmu.zig");
const sbi = @import("sbi.zig");
const uart = @import("uart.zig");
// trap.zig: excluded (ELF linksection incompatible with macOS test runner)

comptime {
    _ = mmu;
    _ = sbi;
    _ = uart;
}
