//! Kernel trace ring.
//!
//! The ring stores compact scheduler events during early bring-up. It is kept
//! separate from `task` so the boot log stage maps to a real kernel module.

pub const TRACE_EVENTS: usize = 128;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceKind {
    SchedSwitch,
    SchedEnqueue,
    SchedDequeue,
    SchedTick,
    SchedBlock,
    SchedWake,
    SchedYield,
    SchedExit,
    SchedPreempt,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TraceEvent {
    pub kind: TraceKind,
    pub subject: u64,
    pub object: u64,
    pub value: u64,
}

impl TraceEvent {
    const EMPTY: Self = Self {
        kind: TraceKind::SchedTick,
        subject: 0,
        object: 0,
        value: 0,
    };
}

pub struct Ring<const N: usize> {
    events: [TraceEvent; N],
    cursor: usize,
    len: usize,
}

impl<const N: usize> Ring<N> {
    pub const fn new() -> Self {
        Self {
            events: [TraceEvent::EMPTY; N],
            cursor: 0,
            len: 0,
        }
    }

    pub fn emit(&mut self, event: TraceEvent) {
        self.events[self.cursor] = event;
        self.cursor = (self.cursor + 1) & (N - 1);
        self.len = core::cmp::min(self.len + 1, N);
    }

    pub const fn len(&self) -> usize {
        self.len
    }

    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }
}

impl<const N: usize> Default for Ring<N> {
    fn default() -> Self {
        Self::new()
    }
}

const _: () = assert!(TRACE_EVENTS.is_power_of_two());
