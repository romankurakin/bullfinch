//! Timer Hardware Abstraction.
//!
//! Unified interface for architecture-specific timers:
//! ARM Generic Timer, RISC-V SBI timer.
//!
//! We use absolute deadlines rather than relative intervals: next = now + interval.
//! This prevents drift accumulation that would occur if we reset a countdown timer.

const builtin = @import("builtin");

const fdt = @import("../fdt/fdt.zig");
const hal = @import("hal.zig");

const arch_timer = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/timer.zig"),
    .riscv64 => @import("../arch/riscv64/timer.zig"),
    else => @compileError("Unsupported architecture"),
};

const panic_msg = struct {
    const NO_DTB = "TIMER: no DTB available";
};

/// Timer frequency in Hz. Must call initFrequency() before use.
pub fn frequency() u64 {
    return arch_timer.frequency;
}

/// Current timer counter value in ticks.
pub const now = arch_timer.now;

/// Set next timer interrupt deadline (absolute counter value).
pub const setDeadline = arch_timer.setDeadline;

/// Enable timer interrupts. Gets DTB from HAL and passes to arch timer.
pub fn start() void {
    const dtb = hal.getDtb() orelse @panic(panic_msg.NO_DTB);
    arch_timer.start(dtb);
}

/// Initialize timer frequency. ARM64 ignores parameter (reads register).
pub const initFrequency = arch_timer.initFrequency;

/// Convert ticks to nanoseconds.
pub fn ticksToNs(ticks: u64) u64 {
    const ns_per_sec: u128 = 1_000_000_000;
    return @truncate(@as(u128, ticks) * ns_per_sec / frequency());
}

/// Convert nanoseconds to ticks.
pub fn nsToTicks(ns: u64) u64 {
    const ns_per_sec: u128 = 1_000_000_000;
    return @truncate(@as(u128, ns) * frequency() / ns_per_sec);
}
