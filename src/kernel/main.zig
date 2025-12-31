//! Architecture-independent kernel entry point for Bullfinch.
//! Runs at physical address until MMU init, then transitions to higher-half.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
}

const arch_name = switch (builtin.target.cpu.arch) {
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V",
    else => "Unknown",
};

pub export fn main() callconv(.c) void {
    hal.init();
    hal.print("\nHardware initialized\n");
    hal.initMmu();
    hal.print("MMU enabled\n");

    hal.jumpToHigherHalf(kmain, 0);
}

/// Kernel entry point running in higher-half virtual address space.
fn kmain(_: usize) noreturn {
    hal.print("Running in higher-half virtual address space\n");

    // Switch MMIO to higher-half addresses before removing identity mapping.
    // Must happen first so peripherals remain accessible after mapping removal.
    hal.useHigherHalfAddresses();
    hal.removeIdentityMapping();
    hal.print("Identity mapping removed\n");

    hal.initTrap();
    hal.print("Trap handling initialized\n");

    hal.print("Welcome to Bullfinch on ");
    hal.print(arch_name);
    hal.print(" architecture\n");

    // Test trap handling - triggers breakpoint and displays register dump
    hal.trap.testTriggerBreakpoint();

    hal.print("Boot complete. Halting.\n");
    hal.halt();
}

var panicking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Kernel panic handler. Prints message and halts. Guards against double panic.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    // Double panic guard - halt immediately if already panicking
    if (panicking.swap(true, .acquire)) hal.halt();

    hal.print("\nPanic: ");
    hal.print(msg);
    hal.print("\n");
    hal.halt();
}
