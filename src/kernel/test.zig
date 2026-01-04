//! Kernel root - imports all kernel modules for testing

const arm64 = @import("arch/arm64/test.zig");
const kernel = @import("kernel.zig");
const riscv64 = @import("arch/riscv64/test.zig");

// Ensure all modules are imported so their inline tests run
comptime {
    _ = arm64;
    _ = kernel;
    _ = riscv64;
}
