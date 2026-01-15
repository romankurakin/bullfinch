//! RISC-V Timer via SBI.
//!
//! Unlike ARM where the timer is directly accessible, RISC-V timer registers (mtime,
//! mtimecmp) are in M-mode. The kernel in S-mode must use SBI calls to set deadlines.
//! The TIME extension (sbi_set_timer) programs mtimecmp and clears pending interrupts.
//!
//! The time CSR (readable via rdtime) provides the current counter. On trap, we set
//! the next deadline via SBI. This is the foundation for preemptive scheduling.
//!
//! See RISC-V SBI Specification, Chapter 6 (Timer Extension).

const sbi = @import("sbi.zig");

const panic_msg = struct {
    const ZERO_FREQUENCY = "TIMER: frequency is zero";
};

/// Timer frequency in Hz. Set by initFrequency() before use.
pub var frequency: u64 = 0;

/// Set timer frequency.
pub fn initFrequency(freq: u64) void {
    if (freq == 0) @panic(panic_msg.ZERO_FREQUENCY);
    frequency = freq;
}

// CSR bit positions - named constants for clarity
const SIE_STIE: u64 = 1 << 5; // Supervisor Timer Interrupt Enable
const SSTATUS_SIE: u64 = 1 << 1; // Supervisor Interrupt Enable (global)

/// Read current counter value in ticks.
pub inline fn now() u64 {
    return asm volatile ("rdtime %[time]"
        : [time] "=r" (-> u64),
    );
}

/// Set absolute deadline in ticks. Timer fires when counter reaches this value.
pub inline fn setDeadline(absolute_ticks: u64) void {
    sbi.setTimer(absolute_ticks);
}

inline fn enableTimerInterrupt() void {
    asm volatile ("csrs sie, %[mask]"
        :
        : [mask] "r" (SIE_STIE),
    );
}

inline fn enableGlobalInterrupts() void {
    asm volatile ("csrs sstatus, %[mask]"
        :
        : [mask] "r" (SSTATUS_SIE),
    );
}

/// Enable timer interrupts and global interrupt delivery.
/// Caller must set a deadline via setDeadline() before calling this,
/// otherwise stale mtimecmp could trigger immediate interrupt storm.
pub fn init() void {
    enableTimerInterrupt();
    enableGlobalInterrupts();
}
