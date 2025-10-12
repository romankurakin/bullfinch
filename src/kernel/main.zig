//! Architecture-independent kernel entry point for Bullfinch.
//! This is the first C-callable function with a valid runtime; all prior code is assembly.

const boot = switch (@import("builtin").target.cpu.arch) {
    .aarch64 => @import("arch/arm64/boot.zig"),
    .riscv64 => @import("arch/riscv64/boot.zig"),
    else => @compileError("Unsupported architecture"),
};

const board = @import("board");
const hal = board.hal;

comptime {
    _ = boot; // Ensure boot code is linked in despite no runtime references
}

pub export fn main() callconv(.c) void {
    hal.init();

    const arch_str = switch (@import("builtin").target.cpu.arch) {
        .aarch64 => "ARM64",
        .riscv64 => "RISC-V",
        else => "Unknown",
    };
    hal.print("Hello from Bullfinch on ");
    hal.print(arch_str);
    hal.print("!\n");

    while (true) {
        asm volatile ("wfi"); // ARM64 and RISC-V idle instruction - safe infinite wait for interrupts
    }
}

pub fn panic(_: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
