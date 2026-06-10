//! Time and timer-counter units.
//!
//! Keep frequency, durations, and absolute deadlines distinct. They are all
//! represented as integers by hardware, but mixing them is a common kernel bug.

use core::num::NonZeroU64;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct Frequency(NonZeroU64);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct Ticks(u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct TickInterval(NonZeroU64);

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct Deadline(u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TimerError {
    DeadlineRejected,
}

impl Frequency {
    pub const fn new(hz: NonZeroU64) -> Self {
        Self(hz)
    }

    pub const fn get(self) -> u64 {
        self.0.get()
    }

    pub fn try_from_hz(hz: u64) -> Option<Self> {
        NonZeroU64::new(hz).map(Self)
    }
}

impl Ticks {
    pub const ZERO: Self = Self(0);

    pub const fn new(raw: u64) -> Self {
        Self(raw)
    }

    pub const fn get(self) -> u64 {
        self.0
    }
}

impl TickInterval {
    pub const fn new(raw: NonZeroU64) -> Self {
        Self(raw)
    }

    pub const fn get(self) -> u64 {
        self.0.get()
    }

    pub fn try_from_ticks(ticks: Ticks) -> Option<Self> {
        NonZeroU64::new(ticks.get()).map(Self)
    }
}

impl Deadline {
    pub const fn new(raw: u64) -> Self {
        Self(raw)
    }

    pub const fn get(self) -> u64 {
        self.0
    }

    pub fn checked_after(self, interval: TickInterval) -> Option<Self> {
        self.0.checked_add(interval.get()).map(Self)
    }
}
