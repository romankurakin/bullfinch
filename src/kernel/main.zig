//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after physInit() enables MMU and switches to
//! higher-half addresses. We finalize the virtual address space transition,
//! initialize physical memory manager and clock, then enter the idle loop.

const builtin = @import("builtin");
const std = @import("std");

const kernel = @import("kernel.zig");
const pmm = @import("pmm/pmm.zig");
const hal = @import("hal/hal.zig");

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

fn printDtbInfo(dtb: kernel.fdt.Fdt) void {
    hal.console.print("CPUs: ");
    hal.console.printDec(kernel.fdt.getCpuCount(dtb));
    hal.console.print("\n");

    hal.console.print("RAM: ");
    hal.console.printDec(kernel.fdt.getTotalMemory(dtb) / (1024 * 1024));
    hal.console.print(" MB\n");

    var reserved = kernel.fdt.getReservedRegions(dtb);
    while (reserved.next()) |region| {
        hal.console.print("Reserved: ");
        hal.console.printHex(region.base);
        hal.console.print(" - ");
        hal.console.printHex(region.base + region.size);
        hal.console.print("\n");
    }
}

/// Kernel main, called from boot.zig after MMU enables higher-half mapping.
export fn kmain() noreturn {
    hal.virtInit();

    hal.console.print("Welcome to Bullfinch on ");
    hal.console.print(arch_name);
    hal.console.print(" architecture\n");

    // Get DTB once and pass to all functions
    const dtb = hal.getDtb() orelse @panic(panic_msg.NO_DTB);

    printDtbInfo(dtb);

    // Initialize physical memory manager
    pmm.init(dtb);
    hal.console.print("PMM: ");
    hal.console.printDec(pmm.freeCount());
    hal.console.print("/");
    hal.console.printDec(pmm.totalPages());
    hal.console.print(" pages free\n");

    kernel.clock.init();
    hal.console.print("Clock initialized\n");

    hal.console.print("Waiting for timer ticks");
    const target_ticks: u64 = 10;
    while (kernel.clock.getTickCount() < target_ticks) {
        hal.waitForInterrupt();
    }
    hal.console.print(" done\n");
    hal.console.print("Clock: ");
    hal.console.printDec(kernel.clock.getTickCount());
    hal.console.print(" ticks\n");

    kernel.debug.dumpPmmLeaks();

    hal.console.print("Boot complete. Halting.\n");
    hal.halt();
}

var panicking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Kernel panic handler. Prints message and halts. Guards against double panic.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    hal.disableInterrupts();
    if (panicking.swap(true, .acquire)) hal.halt();

    hal.console.print("\nPanic: ");
    hal.console.print(msg);
    hal.console.print("\n");
    hal.halt();
}
