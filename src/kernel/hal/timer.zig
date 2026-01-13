//! Timer Hardware Abstraction.
//!
//! Unified interface for architecture-specific timers:
//! ARM Generic Timer, RISC-V SBI timer.
//!
//! We use absolute deadlines rather than relative intervals: next = now + interval.
//! This prevents drift accumulation that would occur if we reset a countdown timer.

const builtin = @import("builtin");

const fdt = @import("../fdt/fdt.zig");

const arch_timer = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/timer.zig"),
    .riscv64 => @import("../arch/riscv64/timer.zig"),
    else => @compileError("Unsupported architecture"),
};

/// Timer frequency in Hz. Must call initFrequency() before use.
pub fn frequency() u64 {
    return arch_timer.frequency;
}

/// Current timer counter value in ticks.
pub const now = arch_timer.now;

/// Set next timer interrupt deadline (absolute counter value).
pub const setDeadline = arch_timer.setDeadline;

/// Enable timer interrupts. Caller must initialize interrupt controller first.
pub fn start(dtb: fdt.Fdt) void {
    arch_timer.start(dtb);
}

/// Initialize timer frequency. ARM64 ignores parameter (reads register).
pub const initFrequency = arch_timer.initFrequency;
