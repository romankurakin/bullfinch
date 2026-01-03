//! Kernel console output.
//! Initialized early in boot with UART address, updated when switching to virtual.

const builtin = @import("builtin");

const backend = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/uart.zig"),
    .riscv64 => @import("../arch/riscv64/uart.zig"),
    else => @compileError("Unsupported architecture"),
};

const config = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/boards/qemu_virt/config.zig"),
    .riscv64 => @import("../arch/riscv64/boards/qemu_virt/config.zig"),
    else => @compileError("Unsupported architecture"),
};

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
