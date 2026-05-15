//! RISC-V supervisor timer access.
//!
//! The supervisor timer is owned by machine-mode firmware (OpenSBI). We
//! program deadlines via SBI calls and enable delivery through the local
//! interrupt controller (PLIC or CLINT).

use core::arch::asm;
use core::sync::atomic::{AtomicU64, Ordering};

use kernel::time::{Deadline, Frequency, Ticks, TimerError};

use super::{cpu, interrupt, sbi};

const SUPERVISOR_TIMER_INTERRUPT_ENABLE: usize = 1 << 5;

// 0 == not yet initialized. See aarch64/timer.rs for the rationale.
static FREQUENCY_HZ: AtomicU64 = AtomicU64::new(0);

pub fn init_frequency(frequency: Option<Frequency>) {
    let hz = frequency.map(Frequency::get).unwrap_or(0);
    FREQUENCY_HZ.store(hz, Ordering::Release);
}

pub fn frequency() -> Option<Frequency> {
    Frequency::try_from_hz(FREQUENCY_HZ.load(Ordering::Acquire))
}

pub fn now() -> Ticks {
    let raw: u64;

    // SAFETY: `time` is a read-only counter CSR exposed to supervisor mode.
    unsafe {
        asm!("rdtime {raw}", raw = out(reg) raw, options(nomem, nostack, preserves_flags));
    }

    Ticks::new(raw)
}

pub fn set_deadline(deadline: Deadline) -> Result<(), TimerError> {
    sbi::set_timer(deadline.get()).map_err(|_| TimerError::DeadlineRejected)
}

pub fn enable_local_timer_interrupts() {
    // SAFETY: Setting SIE.STIE enables supervisor timer interrupts for this
    // hart. A deadline should be programmed before this is called.
    unsafe {
        asm!(
            "csrs sie, {mask}",
            mask = in(reg) SUPERVISOR_TIMER_INTERRUPT_ENABLE,
            options(nomem, nostack, preserves_flags)
        );
    }
}

pub fn enable() -> Result<(), TimerError> {
    interrupt::enable_timer_interrupt();
    cpu::enable_interrupts();
    Ok(())
}
