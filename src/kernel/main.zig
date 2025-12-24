//! Architecture-independent kernel entry point for Bullfinch.
//! This is the first C-callable function with a valid runtime; all prior code is assembly.

const std = @import("std");
const arch = @import("builtin").target.cpu.arch;

const boot = switch (arch) {
    .aarch64 => @import("arch/arm64/boot.zig"),
    .riscv64 => @import("arch/riscv64/boot.zig"),
    else => @compileError("Unsupported architecture"),
};

const board = @import("board");
const hal = board.hal;

// Architecture-specific trap handling (exceptions + interrupts)
const trap = switch (arch) {
    .aarch64 => @import("arch/arm64/trap.zig"),
    .riscv64 => @import("arch/riscv64/trap.zig"),
    else => @compileError("Unsupported architecture"),
};

comptime {
    _ = boot;
}

const arch_name = switch (arch) {
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V",
    else => "Unknown",
};

pub export fn main() callconv(.c) void {
    hal.init();

    hal.print("Bullfinch on ");
    hal.print(arch_name);
    hal.print(" architecture\n");
    trap.init();

    hal.print("Trap handlers initialized\n");

    trap.testTriggerBreakpoint();

    hal.print("error: Returned from trap!\n");
    trap.halt();
}

var panicking: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    // Double panic guard - halt immediately if already panicking
    if (panicking.swap(true, .acquire)) trap.halt();

    hal.print("\nPanic: ");
    hal.print(msg);
    hal.print("\n");
    trap.halt();
}
