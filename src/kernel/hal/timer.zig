//! Timer HAL.
//!
//! Unified interface for ARM Generic Timer and RISC-V SBI timer.
//!
//! Use absolute deadlines rather than relative intervals. This avoids drift that
//! builds up when resetting a countdown timer.

const builtin = @import("builtin");

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

/// Set next timer interrupt deadline as an absolute counter value.
pub const setDeadline = arch_timer.setDeadline;

/// Enable timer interrupts. Caller must initialize interrupt controller first.
pub const init = arch_timer.init;

/// Initialize timer frequency. ARM64 ignores parameter and reads register.
pub const initFrequency = arch_timer.initFrequency;
