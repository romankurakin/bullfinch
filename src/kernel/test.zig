//! Kernel test root.

const arm64 = @import("arch/arm64/test.zig");
const riscv64 = @import("arch/riscv64/test.zig");

const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const debug = @import("debug/debug.zig");
const fdt = @import("fdt/fdt.zig");
const memory = @import("memory/memory.zig");
const mmu = @import("mmu/mmu.zig");
const pmm = @import("pmm/pmm.zig");
const pmm_test = @import("pmm/pmm_test.zig");
const trap = @import("trap/trap.zig");

comptime {
    _ = arm64;
    _ = riscv64;

    _ = clock;
    _ = console;
    _ = debug;
    _ = fdt;
    _ = memory;
    _ = mmu;
    _ = pmm;
    _ = pmm_test;
    _ = trap;
}
