//! Interrupt Controller Hardware Abstraction.
//!
//! Unified interface for architecture-specific interrupt controllers:
//! ARM64 GIC, RISC-V PLIC/CLINT (via SBI).

const builtin = @import("builtin");

const fdt = @import("../fdt/fdt.zig");

const arch_interrupt = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/interrupt.zig"),
    .riscv64 => @import("../arch/riscv64/interrupt.zig"),
    else => @compileError("Unsupported architecture"),
};

/// Initialize interrupt controller. Must be called before timer.start().
pub const init = arch_interrupt.init;
