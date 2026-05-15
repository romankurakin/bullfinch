//! Clock subsystem helpers.
//!
//! Hardware timers use monotonically increasing counters. Absolute deadlines
//! avoid accumulating drift when an interrupt is handled late.

pub const TICK_RATE_HZ: u64 = 100;

use crate::time::{Deadline, Frequency, TickInterval, Ticks};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TickAdvance {
    pub elapsed_ticks: u64,
    pub next_tick: Deadline,
}

pub fn ticks_per_interval(freq: Frequency) -> Option<TickInterval> {
    if freq.get() < TICK_RATE_HZ {
        return None;
    }
    TickInterval::try_from_ticks(Ticks::new(freq.get() / TICK_RATE_HZ))
}

pub fn advance_tick_state(
    now: Ticks,
    scheduled_tick: Deadline,
    interval: TickInterval,
) -> Option<TickAdvance> {
    let mut elapsed_ticks = 1;
    let now = now.get();
    let mut deadline = scheduled_tick.checked_after(interval)?.get();
    let interval = interval.get();

    if deadline <= now {
        let missed = (now - deadline) / interval + 1;
        elapsed_ticks += missed;
        deadline = deadline.checked_add(missed.checked_mul(interval)?)?;
    }

    Some(TickAdvance {
        elapsed_ticks,
        next_tick: Deadline::new(deadline),
    })
}

pub fn ticks_to_ns(ticks: Ticks, frequency: Frequency) -> u64 {
    ((u128::from(ticks.get()) * 1_000_000_000u128) / u128::from(frequency.get())) as u64
}

pub fn ticks_to_us(ticks: Ticks, frequency: Frequency) -> u64 {
    ((u128::from(ticks.get()) * 1_000_000u128) / u128::from(frequency.get())) as u64
}

pub fn ns_to_ticks(ns: u64, frequency: Frequency) -> Ticks {
    Ticks::new(((u128::from(ns) * u128::from(frequency.get())) / 1_000_000_000u128) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_ticks_per_interval() {
        assert_eq!(Frequency::try_from_hz(0), None);
        assert_eq!(ticks_per_interval(freq(99)), None);
        assert_eq!(ticks_per_interval(freq(100)), interval(1));
        assert_eq!(ticks_per_interval(freq(200)), interval(2));
        assert_eq!(ticks_per_interval(freq(12_300)), interval(123));
    }

    #[test]
    fn advances_single_elapsed_tick() {
        assert_eq!(
            advance_tick_state(
                Ticks::new(1_000),
                Deadline::new(1_000),
                interval(100).unwrap()
            ),
            Some(TickAdvance {
                elapsed_ticks: 1,
                next_tick: Deadline::new(1_100),
            })
        );
    }

    #[test]
    fn accounts_for_missed_intervals() {
        assert_eq!(
            advance_tick_state(
                Ticks::new(1_350),
                Deadline::new(1_000),
                interval(100).unwrap()
            ),
            Some(TickAdvance {
                elapsed_ticks: 4,
                next_tick: Deadline::new(1_400),
            })
        );
    }

    #[test]
    fn rejects_zero_tick_interval() {
        assert_eq!(TickInterval::try_from_ticks(Ticks::ZERO), None);
    }

    #[test]
    fn converts_timer_units() {
        assert_eq!(ticks_to_ns(Ticks::new(1), freq(1_000_000_000)), 1);
        assert_eq!(ticks_to_us(Ticks::new(1_000), freq(1_000_000)), 1_000);
        assert_eq!(ns_to_ticks(1_000_000, freq(1_000_000)), Ticks::new(1_000));
    }

    fn freq(hz: u64) -> Frequency {
        Frequency::try_from_hz(hz).unwrap()
    }

    fn interval(ticks: u64) -> Option<TickInterval> {
        TickInterval::try_from_ticks(Ticks::new(ticks))
    }
}
