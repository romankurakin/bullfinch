//! Board description for QEMU's "virt" machine, shared across architectures.

const builtin = @import("builtin");
pub const arm64 = struct {
    // PL011 UART MMIO base address for QEMU virt. Direct hardware access.
    pub const uart_base: usize = 0x0900_0000;
};

pub const riscv64 = struct {
    // RISC-V uses SBI firmware for console; no kernel MMIO needed for isolation.
    pub const uart_base: ?usize = null;
};

// HAL selected by target architecture. Provides uniform init/print interface.
pub const hal = switch (builtin.target.cpu.arch) {
    .aarch64 => struct {
        const pl011 = @import("arm64_uart");
        var state = pl011.State{};

        pub fn init() void {
            pl011.initDefault(arm64.uart_base, &state);
        }

        pub fn print(s: []const u8) void {
            pl011.print(arm64.uart_base, &state, s);
        }
    },
    .riscv64 => struct {
        const sbi_uart = @import("riscv_uart");

        pub fn init() void {
            sbi_uart.init();
        }

        pub fn print(s: []const u8) void {
            sbi_uart.print(s);
        }
    },
    else => @compileError("QEMU virt board not supported on this architecture"),
};
