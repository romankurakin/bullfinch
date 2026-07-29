//! Runtime clock state.
//!
//! The timer interrupt counts ticks and schedules the next deadline without a
//! lock. The handler already runs with interrupts disabled, so shared state is
//! published through atomics.

use core::sync::atomic::{AtomicU64, Ordering};

use kernel::{
    clock,
    time::{Deadline, TickInterval, Ticks, TimerError},
};

use crate::hal;

static TICKS_PER_INTERVAL: AtomicU64 = AtomicU64::new(0);
static NEXT_TICK: AtomicU64 = AtomicU64::new(0);
static TICK_COUNT: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClockError {
    MissingFrequency,
    InvalidFrequency,
    DeadlineOverflow,
    Timer(TimerError),
    FirstTickTimeout,
}

pub fn init() -> Result<(), ClockError> {
    let frequency = hal::timer::frequency().ok_or(ClockError::MissingFrequency)?;
    let interval = clock::ticks_per_interval(frequency).ok_or(ClockError::InvalidFrequency)?;
    let now = hal::timer::now();
    let next = Deadline::new(
        now.get()
            .checked_add(interval.get())
            .ok_or(ClockError::DeadlineOverflow)?,
    );

    TICKS_PER_INTERVAL.store(interval.get(), Ordering::Relaxed);
    NEXT_TICK.store(next.get(), Ordering::Relaxed);
    TICK_COUNT.store(0, Ordering::Relaxed);
    hal::timer::set_deadline(next).map_err(ClockError::Timer)
}

pub fn handle_timer_irq() -> bool {
    let Some(interval) =
        TickInterval::try_from_ticks(Ticks::new(TICKS_PER_INTERVAL.load(Ordering::Relaxed)))
    else {
        clock_fatal("clock: invalid timer state");
    };

    let scheduled = Deadline::new(NEXT_TICK.load(Ordering::Relaxed));
    let Some(advance) = clock::advance_tick_state(hal::timer::now(), scheduled, interval) else {
        clock_fatal("clock: timer deadline overflow");
    };

    // TODO(smp): make the clock state per-CPU before secondary CPUs receive
    // timer interrupts. This load/store update relies on one interrupt-side writer.
    let tick_count = TICK_COUNT
        .load(Ordering::Relaxed)
        .wrapping_add(advance.elapsed_ticks);
    TICK_COUNT.store(tick_count, Ordering::Relaxed);
    let should_reschedule = kernel::task::tick(advance.elapsed_ticks)
        .unwrap_or_else(|_| clock_fatal("clock: scheduler tick failed"));
    NEXT_TICK.store(advance.next_tick.get(), Ordering::Relaxed);
    if hal::timer::set_deadline(advance.next_tick).is_err() {
        clock_fatal("clock: timer deadline rejected");
    }
    should_reschedule
}

fn clock_fatal(message: &str) -> ! {
    crate::console::print_unsafe("\n[PANIC]\n");
    crate::console::print_unsafe(message);
    crate::console::print_unsafe("\n");
    hal::cpu::halt()
}

pub fn wait_for_first_tick(max_spins: usize) -> Result<(), ClockError> {
    let mut spins = 0;
    while spins < max_spins {
        if TICK_COUNT.load(Ordering::Relaxed) != 0 {
            return Ok(());
        }
        core::hint::spin_loop();
        spins += 1;
    }

    Err(ClockError::FirstTickTimeout)
}
