//! Architecture-independent kernel entry point for Bullfinch.
//! This is the first C-callable function with a valid runtime; all prior code is assembly.

const boot = switch (@import("builtin").target.cpu.arch) {
    .aarch64 => @import("arch/arm64/boot.zig"),
    .riscv64 => @import("arch/riscv64/boot.zig"),
    else => @compileError("Unsupported architecture"),
};

const board = @import("board");
const hal = board.hal;

// Architecture-specific trap handling (exceptions + interrupts)
const trap = switch (@import("builtin").target.cpu.arch) {
    .aarch64 => @import("arch/arm64/trap.zig"),
    .riscv64 => @import("arch/riscv64/trap.zig"),
    else => @compileError("Unsupported architecture"),
};

comptime {
    _ = boot;
}

pub export fn main() callconv(.c) void {
    hal.init();

    const arch_str = switch (@import("builtin").target.cpu.arch) {
        .aarch64 => "ARM64",
        .riscv64 => "RISC-V",
        else => "Unknown",
    };

    hal.print("Bullfinch on ");
    hal.print(arch_str);
    hal.print(" architecture\n");
    trap.init();

    hal.print("Trap handlers initialized\n");
    
    trap.testTriggerBreakpoint();

    hal.print("error: Returned from trap!\n");
    while (true) {
        asm volatile ("wfi");
    }
}

var panicking = false;

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    if (panicking) trap.halt(); // Double panic - halt immediately
    panicking = true;

    hal.print("\nPanic: ");
    hal.print(msg);
    hal.print("\n");
    trap.halt();
}
