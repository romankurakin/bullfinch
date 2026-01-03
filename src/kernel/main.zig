//! Architecture-independent kernel entry point for Bullfinch.
//!
//! Boot sequence is handled by HAL to enforce correct ordering.

const std = @import("std");
const builtin = @import("builtin");
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

    hal.print("Welcome to Bullfinch on ");
    hal.print(arch_name);
    hal.print(" architecture\n");

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
