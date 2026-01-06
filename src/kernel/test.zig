//! Kernel test root.

const arm64 = @import("arch/arm64/test.zig");
const kernel = @import("kernel.zig");
const pmm = @import("pmm/pmm.zig");
const pmm_test = @import("pmm/pmm_test.zig");
const riscv64 = @import("arch/riscv64/test.zig");

comptime {
    _ = arm64;
    _ = kernel;
    _ = pmm;
    _ = pmm_test;
    _ = riscv64;
}
