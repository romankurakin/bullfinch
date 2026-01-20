//! ARM64 Generic Timer.
//!
//! The ARM Generic Timer is a system-wide counter with per-CPU comparators. Each CPU
//! can set a deadline; when the counter reaches that value, the timer fires an
//! interrupt. This is the foundation for preemptive scheduling.
//!
//! We use CNTP (EL1 physical timer) which generates PPI 30. The "physical" timer
//! counts real time, unlike the "virtual" timer which can be offset for VM guests.
//! For a bare-metal kernel, physical is the right choice.
//!
//! Key registers:
//! - CNTFRQ_EL0: Counter frequency in Hz (read-only, set by firmware)
//! - CNTPCT_EL0: Current counter value (read-only, monotonically increasing)
//! - CNTP_CVAL_EL0: Comparator value (interrupt fires when counter >= this)
//! - CNTP_CTL_EL0: Timer control (ENABLE, IMASK, ISTATUS bits)
//!
//! See ARM Architecture Reference Manual, Chapter D12 (The Generic Timer).

const gic = @import("gic.zig");

const panic_msg = struct {
    const ZERO_FREQUENCY = "timer: CNTFRQ_EL0 is zero (firmware bug)";
};

/// CNTP_CTL_EL0 bit: Enable timer.
const CNTP_CTL_ENABLE: u64 = 1 << 0;

/// Timer frequency in Hz. Read from CNTFRQ_EL0 register.
pub var frequency: u64 = 0;

/// Read frequency from CNTFRQ_EL0 (set by firmware at boot).
/// The freq parameter is ignored - ARM64 reads the register directly.
/// Panics if firmware left CNTFRQ_EL0 at zero (broken firmware).
pub fn initFrequency(_: u64) void {
    frequency = asm volatile ("mrs %[freq], cntfrq_el0"
        : [freq] "=r" (-> u64),
    );
    if (frequency == 0) @panic(panic_msg.ZERO_FREQUENCY);
}

/// Read current counter value in ticks.
pub inline fn now() u64 {
    return asm volatile ("mrs %[cnt], cntpct_el0"
        : [cnt] "=r" (-> u64),
    );
}

/// Set absolute deadline in ticks. Timer fires when counter reaches this value.
pub inline fn setDeadline(absolute_ticks: u64) void {
    asm volatile ("msr cntp_cval_el0, %[val]"
        :
        : [val] "r" (absolute_ticks),
    );
}

/// Enable timer: CNTP_CTL_EL0 ENABLE=1, IMASK=0.
inline fn enableTimer() void {
    asm volatile ("msr cntp_ctl_el0, %[val]"
        :
        : [val] "r" (CNTP_CTL_ENABLE),
    );
    asm volatile ("isb");
}

/// Unmask IRQ bit in DAIF to enable IRQ delivery.
inline fn enableIrq() void {
    asm volatile ("msr daifclr, #2");
}

/// Enable timer interrupts and global interrupt delivery.
/// Caller must initialize interrupt controller first.
pub fn init() void {
    gic.enableTimerInterrupt();
    enableTimer();
    enableIrq();
}
