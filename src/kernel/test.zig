//! Kernel Test Root.
//!
//! Modules with linksection attributes or hardware dependencies are excluded.

const builtin = @import("builtin");

const fdt = @import("fdt/fdt.zig");
const hwinfo = @import("hwinfo/hwinfo.zig");
const memory = @import("memory/memory.zig");
const once = @import("sync/once.zig");
const pmm = @import("pmm/pmm.zig");
const ticket = @import("sync/ticket.zig");
const trap = @import("trap/trap.zig");

const arch_mmu = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/arm64/mmu.zig"),
    .riscv64 => @import("arch/riscv64/mmu.zig"),
    else => struct {},
};

const arch_trap_entry = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/arm64/trap_entry.zig"),
    .riscv64 => @import("arch/riscv64/trap_entry.zig"),
    else => struct {},
};

const arch_uart = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/arm64/uart.zig"),
    .riscv64 => @import("arch/riscv64/uart.zig"),
    else => struct {},
};

comptime {
    _ = fdt;
    _ = hwinfo;
    _ = memory;
    _ = once;
    _ = pmm;
    _ = ticket;
    _ = trap;
    _ = arch_mmu;
    _ = arch_trap_entry;
    _ = arch_uart;
}
