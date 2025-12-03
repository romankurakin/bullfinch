//! Kernel root - imports all kernel modules for testing

const arm64 = @import("arch/arm64/root_test.zig");
const riscv64 = @import("arch/riscv64/root_test.zig");

// Ensure all modules are imported so their inline tests run
comptime {
    _ = arm64;
    _ = riscv64;
}
