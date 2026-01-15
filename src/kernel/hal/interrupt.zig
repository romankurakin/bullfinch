//! Interrupt controller HAL.
//!
//! Unified interface for ARM64 GIC and RISC-V PLIC CLINT via SBI.

const builtin = @import("builtin");

const arch_interrupt = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/interrupt.zig"),
    .riscv64 => @import("../arch/riscv64/interrupt.zig"),
    else => @compileError("Unsupported architecture"),
};

/// Initialize interrupt controller. Must be called before timer.start().
pub const init = arch_interrupt.init;
