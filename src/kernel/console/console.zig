//! Kernel Console Output.
//!
//! Early boot console for kernel messages. Architecture-specific UART backends
//! (PL011 for ARM, SBI for RISC-V) are selected at compile time.
//!
//! This is a temporary kernel-mode driver. Eventually UART access moves to
//! userspace. The kernel will just provide MMIO VMOs and IRQ capabilities.

const builtin = @import("builtin");

const backend = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/uart.zig"),
    .riscv64 => @import("../arch/riscv64/uart.zig"),
    else => @compileError("Unsupported architecture"),
};

const config = @import("board").config;

var uart_base: usize = if (@hasDecl(config, "UART_PHYS")) config.UART_PHYS else 0;

/// Initialize console output.
pub fn init() void {
    if (builtin.cpu.arch == .aarch64) {
        backend.initDefault(uart_base);
    } else {
        backend.init();
    }
}

/// Update UART base address (for physical to virtual transition).
pub fn setBase(addr: usize) void {
    uart_base = addr;
}

/// Print string to console.
pub fn print(s: []const u8) void {
    if (builtin.cpu.arch == .aarch64) {
        backend.print(uart_base, s);
    } else {
        backend.print(s);
    }
}
