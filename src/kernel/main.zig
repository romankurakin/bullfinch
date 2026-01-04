//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after stack and BSS setup. We run two-phase boot
//! (physical then virtual), initialize clock for timer interrupts, and enter the
//! idle loop. Later we'll start the scheduler here.

const builtin = @import("builtin");
const std = @import("std");

const clock = @import("kernel.zig").clock;
const hal = @import("hal/hal.zig");

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
}

const arch_name = switch (builtin.target.cpu.arch) {
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V",
    else => "Unknown",
};

/// Entry point called from boot (runs at physical addresses).
pub export fn main() callconv(.c) void {
    hal.bootPhysical(kmain, 0);
}

fn kmain(_: usize) noreturn {
    hal.bootVirtual();

    hal.console.print("Welcome to Bullfinch on ");
    hal.console.print(arch_name);
    hal.console.print(" architecture\n");

    clock.init();
    hal.console.print("Clock initialized\n");

    hal.console.print("Waiting for timer ticks");
    const target_ticks: u64 = 10;
    while (clock.getTickCount() < target_ticks) {
        hal.waitForInterrupt();
    }
    hal.console.print("\n");
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
