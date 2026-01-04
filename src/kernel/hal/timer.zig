//! Timer Hardware Abstraction.
//!
//! Unified interface for architecture-specific timers:
//! ARM Generic Timer, RISC-V SBI timer.
//!
//! We use absolute deadlines rather than relative intervals: next = now + interval.
//! This prevents drift accumulation that would occur if we reset a countdown timer.

const builtin = @import("builtin");

const arch_timer = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/timer.zig"),
    .riscv64 => @import("../arch/riscv64/timer.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const frequency = arch_timer.frequency;
pub const now = arch_timer.now;
pub const setDeadline = arch_timer.setDeadline;
pub const start = arch_timer.start;

/// Convert ticks to nanoseconds.
pub fn ticksToNs(ticks: u64) u64 {
    const ns_per_sec: u128 = 1_000_000_000;
    return @truncate(@as(u128, ticks) * ns_per_sec / frequency);
}

/// Convert nanoseconds to ticks.
pub fn nsToTicks(ns: u64) u64 {
    const ns_per_sec: u128 = 1_000_000_000;
    return @truncate(@as(u128, ns) * frequency / ns_per_sec);
}
