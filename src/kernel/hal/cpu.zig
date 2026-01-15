//! CPU primitives HAL.
//!
//! ARM64 uses LDAXR + WFE for low power sleep. RISC-V polls with pause hints.

const builtin = @import("builtin");

const arch_cpu = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/cpu.zig"),
    .riscv64 => @import("../arch/riscv64/cpu.zig"),
    else => @compileError("unsupported architecture"),
};

/// Spin until low 16 bits of value at `ptr` equals `expected`.
pub const spinWaitEq16 = arch_cpu.spinWaitEq16;

/// Speculation barrier for Spectre v1 mitigation. Use after bounds checks on
/// untrusted indices before using them to access arrays.
pub const speculationBarrier = arch_cpu.speculationBarrier;
