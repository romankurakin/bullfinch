//! ARM64 generic timer access.
//!
//! Uses the EL1 physical timer. Interrupt-controller setup stays separate from
//! these local CPU timer registers.

use core::arch::asm;
use core::sync::atomic::{AtomicU64, Ordering};

use kernel::time::{Deadline, Frequency, Ticks, TimerError};

use super::{cpu, interrupt};

const CNTP_CTL_ENABLE: u64 = 1 << 0;

// 0 == not yet initialized. Written once at boot, read from many call sites.
// Using an atomic avoids `static mut` aliasing UB and makes the publication
// edge explicit.
static FREQUENCY_HZ: AtomicU64 = AtomicU64::new(0);

pub fn init_frequency(_: Option<Frequency>) {
    let hz = read_frequency().map(Frequency::get).unwrap_or(0);
    FREQUENCY_HZ.store(hz, Ordering::Release);
}

pub fn frequency() -> Option<Frequency> {
    Frequency::try_from_hz(FREQUENCY_HZ.load(Ordering::Acquire))
}

fn read_frequency() -> Option<Frequency> {
    let raw: u64;

    // SAFETY: CNTFRQ_EL0 is a read-only architectural register that reports the
    // generic timer frequency. Reading it has no side effects.
    unsafe {
        asm!("mrs {raw}, cntfrq_el0", raw = out(reg) raw, options(nomem, nostack, preserves_flags));
    }

    Frequency::try_from_hz(raw)
}

pub fn now() -> Ticks {
    let raw: u64;

    // SAFETY: CNTPCT_EL0 is a read-only monotonically increasing counter.
    unsafe {
        asm!("mrs {raw}, cntpct_el0", raw = out(reg) raw, options(nomem, nostack, preserves_flags));
    }

    Ticks::new(raw)
}

pub fn set_deadline(deadline: Deadline) -> Result<(), TimerError> {
    let raw = deadline.get();

    // SAFETY: Writing CNTP_CVAL_EL0 programs this CPU's physical timer compare
    // value. The caller provides an absolute counter deadline.
    unsafe {
        asm!("msr cntp_cval_el0, {raw}", raw = in(reg) raw, options(nomem, nostack, preserves_flags));
    }
    Ok(())
}

fn enable_local_timer() {
    // SAFETY: CNTP_CTL_EL0 is local CPU state. ENABLE=1 and IMASK=0 allows the
    // programmed physical timer deadline to raise its interrupt.
    unsafe {
        asm!(
            "msr cntp_ctl_el0, {control}",
            "isb",
            control = in(reg) CNTP_CTL_ENABLE,
            options(nomem, nostack, preserves_flags)
        );
    }
}

pub fn enable() -> Result<(), TimerError> {
    interrupt::enable_timer_interrupt();
    enable_local_timer();
    cpu::enable_interrupts();
    Ok(())
}
