//! Kernel test root.

const builtin = @import("builtin");

// Architecture-specific tests contain inline assembly that only compiles for
// their target architecture. Import only the matching arch to allow `zig build test`
// to run on any host without cross-compilation guards in individual modules.
const arch_test = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/arm64/test.zig"),
    .riscv64 => @import("arch/riscv64/test.zig"),
    else => struct {},
};

const alloc = @import("alloc/alloc.zig");
const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const fdt = @import("fdt/fdt.zig");
const hwinfo = @import("hwinfo/hwinfo.zig");
const lib = @import("lib/lib.zig");
const memory = @import("memory/memory.zig");
const mmu = @import("mmu/mmu.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");
const trap = @import("trap/trap.zig");

comptime {
    _ = arch_test;

    _ = alloc;
    _ = clock;
    _ = console;
    _ = fdt;
    _ = hwinfo;
    _ = lib;
    _ = memory;
    _ = mmu;
    _ = pmm;
    _ = sync;
    _ = trap;
}
