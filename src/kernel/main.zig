//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after physInit() enables MMU and switches to
//! higher-half addresses. We finalize the virtual address space transition,
//! initialize clock for timer interrupts, and enter the idle loop.

const builtin = @import("builtin");
const std = @import("std");

const clock = @import("kernel.zig").clock;
const fdt = @import("fdt/fdt.zig");
const hal = @import("hal/hal.zig");

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
    _ = @import("c_compat.zig"); // C stdlib shim for libfdt
}

const arch_name = switch (builtin.target.cpu.arch) {
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V",
    else => "Unknown",
};

/// Print memory info from Device Tree.
fn printDtbInfo(dtb_phys: usize) void {
    if (dtb_phys == 0) return;

    const dtb: fdt.Fdt = @ptrFromInt(hal.physToVirt(dtb_phys));
    fdt.checkHeader(dtb) catch return;

    if (fdt.getMemoryRegion(dtb)) |mem| {
        hal.console.print("RAM: ");
        hal.console.printDec(mem.size / (1024 * 1024));
        hal.console.print(" MB @ ");
        hal.console.printHex(mem.base);
        hal.console.print("\n");
    }
}

/// Kernel main, called from boot.zig after MMU enables higher-half mapping.
export fn kmain() noreturn {
    hal.bootVirtual();

    hal.console.print("Welcome to Bullfinch on ");
    hal.console.print(arch_name);
    hal.console.print(" architecture\n");

    // Print DTB info
    printDtbInfo(hal.getDtbPtr());

    clock.init();
    hal.console.print("Clock initialized\n");

    hal.console.print("Waiting for timer ticks");
    const target_ticks: u64 = 10;
    while (clock.getTickCount() < target_ticks) {
        hal.waitForInterrupt();
    }
    hal.console.print(" done\n");
    clock.printStatus();

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
