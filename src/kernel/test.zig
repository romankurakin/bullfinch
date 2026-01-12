//! Kernel test root.

const arm64 = @import("arch/arm64/test.zig");
const riscv64 = @import("arch/riscv64/test.zig");

const alloc = @import("alloc/alloc.zig");
const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const fdt = @import("fdt/fdt.zig");
const lib = @import("lib/lib.zig");
const memory = @import("memory/memory.zig");
const mmu = @import("mmu/mmu.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");
const trap = @import("trap/trap.zig");

comptime {
    _ = arm64;
    _ = riscv64;

    _ = alloc;
    _ = clock;
    _ = console;
    _ = fdt;
    _ = lib;
    _ = memory;
    _ = mmu;
    _ = pmm;
    _ = sync;
    _ = trap;
}
