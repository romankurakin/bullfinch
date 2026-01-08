//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after physInit() enables MMU and switches to
//! higher-half addresses. We finalize the virtual address space transition,
//! initialize physical memory manager and clock, then enter the idle loop.

const builtin = @import("builtin");
const std = @import("std");

const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const debug = @import("debug/debug.zig");
const fdt = @import("fdt/fdt.zig");
const hal = @import("hal/hal.zig");
const pmm = @import("pmm/pmm.zig");

const panic_msg = struct {
    const NO_DTB = "BOOT: no DTB - cannot discover hardware";
};

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
    _ = @import("c_compat.zig"); // C stdlib shim
}

const arch_name = switch (builtin.target.cpu.arch) {
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V",
    else => "Unknown",
};

fn printDtbInfo(dtb: fdt.Fdt) void {
    console.print("CPUs: ");
    console.printDec(fdt.getCpuCount(dtb));
    console.print("\n");

    console.print("RAM: ");
    console.printDec(fdt.getTotalMemory(dtb) / (1024 * 1024));
    console.print(" MB\n");

    var reserved = fdt.getReservedRegions(dtb);
    while (reserved.next()) |region| {
        console.print("Reserved: ");
        console.printHex(region.base);
        console.print(" - ");
        console.printHex(region.base + region.size);
        console.print("\n");
    }
}

/// Kernel main, called from boot.zig after MMU enables higher-half mapping.
export fn kmain() noreturn {
    hal.virtInit();

    console.print("Welcome to Bullfinch on ");
    console.print(arch_name);
    console.print(" architecture\n");

    // Get DTB once and pass to all functions that need it
    const dtb = hal.getDtb() orelse @panic(panic_msg.NO_DTB);

    printDtbInfo(dtb);

    // Initialize physical memory manager
    pmm.init(dtb);
    console.print("PMM: ");
    console.printDec(pmm.freeCount());
    console.print("/");
    console.printDec(pmm.totalPages());
    console.print(" pages free\n");

    clock.init(dtb);
    console.print("Clock initialized\n");

    console.print("Waiting for timer ticks");
    const target_ticks: u64 = 10;
    while (clock.getTickCount() < target_ticks) {
        hal.waitForInterrupt();
    }
    console.print(" done\n");
    console.print("Clock: ");
    console.printDec(clock.getTickCount());
    console.print(" ticks\n");

    debug.dumpPmmLeaks();

    console.print("Boot complete. Halting.\n");
    hal.halt();
}

var panicking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Kernel panic handler. Prints message and halts. Guards against double panic.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    hal.disableInterrupts();
    if (panicking.swap(true, .acquire)) hal.halt();

    console.print("\nPanic: ");
    console.print(msg);
    console.print("\n");
    hal.halt();
}
