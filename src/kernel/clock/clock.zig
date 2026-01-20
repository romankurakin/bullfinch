//! Clock Subsystem.
//!
//! The clock provides monotonic time and periodic tick callbacks. Ticks are the
//! heartbeat of the kernel — they drive preemptive scheduling, timeouts,
//! and time accounting. Without ticks, a CPU-bound process could run forever.
//!
//! We use a 100 Hz tick rate (10ms per tick). Each tick:
//! 1. Increment the tick counter
//! 2. Schedule the next timer deadline (absolute, not relative, to prevent drift)
//! 3. Call the scheduler hook for preemption (once scheduling is implemented)
//!
//! Monotonic time combines ticks with the hardware counter for sub-tick precision.
//!
//! See OSDI3 Section 2.8 (The Clock Task) and Zircon clock documentation.
//!
//! TODO(smp): tick_count needs atomic access or per-CPU counters
//! TODO(smp): next_tick/scheduler_tick need protection if modified from multiple cores

const console = @import("../console/console.zig");
const hal = @import("../hal/hal.zig");
const trap = @import("../trap/trap.zig");

const panic_msg = struct {
    const ZERO_FREQ = "clock: timer frequency is zero";
};

/// Tick rate for scheduler and periodic work (100 Hz = 10ms ticks).
pub const TICK_RATE_HZ: u64 = 100;

/// Ticks between timer interrupts (computed at init from timer frequency).
var ticks_per_interval: u64 = 0;

/// Next deadline in timer ticks.
var next_tick: u64 = 0;

/// Number of timer ticks since boot.
var tick_count: u64 = 0;

/// Optional scheduler callback, invoked on each tick.
var scheduler_tick: ?*const fn () void = null;

/// Initialize clock subsystem. Timer frequency must be initialized first.
pub fn init() void {
    const freq = hal.timer.frequency();
    if (freq == 0) @panic(panic_msg.ZERO_FREQ);
    ticks_per_interval = freq / TICK_RATE_HZ;

    const now = hal.timer.now();
    next_tick = now + ticks_per_interval;
    hal.timer.setDeadline(next_tick);

    // Deadline must be set before enabling interrupts
    hal.timer.init();
}

/// Register scheduler tick callback. Called once per tick for preemption.
pub fn setSchedulerTick(callback: *const fn () void) void {
    scheduler_tick = callback;
}

/// Handle timer interrupt. Called from trap handler.
pub fn handleTimerIrq() void {
    const now = hal.timer.now();
    tick_count += 1;

    // Absolute deadlines prevent drift; catch up if we missed ticks
    next_tick += ticks_per_interval;
    if (next_tick <= now) {
        const missed = (now - next_tick) / ticks_per_interval + 1;
        next_tick += missed * ticks_per_interval;
    }

    hal.timer.setDeadline(next_tick);

    if (scheduler_tick) |callback| {
        callback();
    }
}

/// Convert timer ticks to nanoseconds.
pub fn ticksToNs(ticks: u64) u64 {
    const ns_per_sec: u128 = 1_000_000_000;
    return @truncate(@as(u128, ticks) * ns_per_sec / hal.timer.frequency());
}

/// Convert nanoseconds to timer ticks.
pub fn nsToTicks(ns: u64) u64 {
    const ns_per_sec: u128 = 1_000_000_000;
    return @truncate(@as(u128, ns) * hal.timer.frequency() / ns_per_sec);
}

/// Get monotonic time in nanoseconds since boot.
/// Combines tick count with sub-tick precision from hardware counter.
pub fn getMonotonicNs() u64 {
    return ticksToNs(hal.timer.now());
}

/// Get number of ticks since boot.
pub inline fn getTickCount() u64 {
    return tick_count;
}

/// Print tick count for debugging (no allocations).
pub fn printStatus() void {
    const dec = trap.fmt.formatDecimal(tick_count);
    console.print("Clock: ");
    console.print(dec.buf[0..dec.len]);
    console.print(" ticks\n");
}
