//! Entropy HAL.
//!
//! Unified interface for collecting hardware entropy on ARM64 and RISC-V.
//! Used for seeding allocator cookies, ASLR, and other security features.
//!
//! Entropy sources by priority:
//! 1. Hardware RNG (RNDR on ARM64, seed CSR on RISC-V)
//! 2. High-resolution cycle counter
//! 3. Address-based entropy (memory layout varies per boot)

const builtin = @import("builtin");

const arch_entropy = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/entropy.zig"),
    .riscv64 => @import("../arch/riscv64/entropy.zig"),
    else => @compileError("Unsupported architecture"),
};

/// Collect entropy from available hardware sources.
/// The addr_hint parameter provides additional variability from memory layout.
pub const collect = arch_entropy.collect;

/// Collect and mix multiple entropy samples for higher quality.
pub const collectMixed = arch_entropy.collectMixed;
