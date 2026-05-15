//! Kernel synchronization primitives.
//!
//! Spin locks are usable before blocking is available and inside interrupt
//! paths. Keep critical sections short and never hold them across operations
//! that can block.

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

const TICKET_SHIFT: u32 = 16;

/// A one-shot flag for boot-time initialization steps.
///
/// This is for admission control, not lazy initialization. If the winner
/// publishes shared data for later readers, use a primitive with an explicit
/// initialization value and publication contract.
pub struct Once {
    done: AtomicBool,
}

impl Once {
    pub const fn new() -> Self {
        Self {
            done: AtomicBool::new(false),
        }
    }

    pub fn try_once(&self) -> bool {
        !self.done.swap(true, Ordering::AcqRel)
    }

    pub fn is_done(&self) -> bool {
        self.done.load(Ordering::Acquire)
    }
}

impl Default for Once {
    fn default() -> Self {
        Self::new()
    }
}

struct TicketLock {
    state: AtomicU32,
}

impl TicketLock {
    const fn new() -> Self {
        Self {
            state: AtomicU32::new(0),
        }
    }

    fn acquire(&self) {
        // INVARIANT: The low half is the owner ticket and the high half is the
        // next ticket. Wrapping is valid while fewer than 2^16 tickets are
        // outstanding.
        let old = self.state.fetch_add(1 << TICKET_SHIFT, Ordering::Acquire);
        let ticket = (old >> TICKET_SHIFT) as u16;
        let owner = old as u16;
        if owner == ticket {
            return;
        }
        while self.state.load(Ordering::Acquire) as u16 != ticket {
            crate::cpu::spin_wait();
        }
    }

    fn try_acquire(&self) -> bool {
        let current = self.state.load(Ordering::Relaxed);
        let owner = current as u16;
        let next = (current >> TICKET_SHIFT) as u16;
        if owner != next {
            return false;
        }
        self.state
            .compare_exchange(
                current,
                current.wrapping_add(1 << TICKET_SHIFT),
                Ordering::Acquire,
                Ordering::Relaxed,
            )
            .is_ok()
    }

    fn release(&self) {
        let state = self.state.load(Ordering::Relaxed);
        debug_assert_ne!(
            state as u16,
            (state >> TICKET_SHIFT) as u16,
            "ticket: release called when lock is not held"
        );
        self.state.fetch_add(1, Ordering::Release);
    }

    #[cfg(test)]
    fn raw(&self) -> u32 {
        self.state.load(Ordering::Relaxed)
    }
}

impl Default for TicketLock {
    fn default() -> Self {
        Self::new()
    }
}

pub struct SpinLock {
    inner: TicketLock,
    // INVARIANT: This is debug state, not owner tracking. It must not gate
    // acquisition because another CPU can hold the lock while this CPU waits.
    held: AtomicBool,
}

impl SpinLock {
    pub const fn new() -> Self {
        Self {
            inner: TicketLock::new(),
            held: AtomicBool::new(false),
        }
    }

    fn lock(&self) {
        self.inner.acquire();
        self.held.store(true, Ordering::Relaxed);
    }

    fn try_lock(&self) -> bool {
        let acquired = self.inner.try_acquire();
        if acquired {
            self.held.store(true, Ordering::Relaxed);
        }
        acquired
    }

    fn unlock(&self) {
        debug_assert!(
            self.held.load(Ordering::Relaxed),
            "spinlock: release called when lock is not held"
        );
        self.held.store(false, Ordering::Relaxed);
        self.inner.release();
    }

    pub fn guard(&self) -> SpinLockGuard<'_> {
        let irq_was_enabled = crate::cpu::disable_interrupts();
        self.lock();
        SpinLockGuard {
            lock: self,
            irq_was_enabled,
        }
    }

    pub fn try_guard(&self) -> Option<SpinLockGuard<'_>> {
        let irq_was_enabled = crate::cpu::disable_interrupts();
        if self.try_lock() {
            Some(SpinLockGuard {
                lock: self,
                irq_was_enabled,
            })
        } else {
            crate::cpu::restore_interrupts(irq_was_enabled);
            None
        }
    }
}

impl Default for SpinLock {
    fn default() -> Self {
        Self::new()
    }
}

#[must_use = "dropping the guard releases the spin lock"]
pub struct SpinLockGuard<'a> {
    lock: &'a SpinLock,
    irq_was_enabled: bool,
}

impl Drop for SpinLockGuard<'_> {
    fn drop(&mut self) {
        self.lock.unlock();
        crate::cpu::restore_interrupts(self.irq_was_enabled);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn once_returns_true_once() {
        let once = Once::new();
        assert!(once.try_once());
        assert!(!once.try_once());
        assert!(once.is_done());
    }

    #[test]
    fn sync_primitives_stay_compact() {
        assert_eq!(core::mem::size_of::<Once>(), 1);
        assert_eq!(core::mem::size_of::<TicketLock>(), 4);
    }

    #[test]
    fn ticket_lock_cycles() {
        let lock = TicketLock::new();
        lock.acquire();
        assert_eq!(lock.raw(), 1 << TICKET_SHIFT);
        lock.release();
        assert_eq!(lock.raw(), (1 << TICKET_SHIFT) | 1);
    }

    #[test]
    fn spin_lock_try_guard() {
        let lock = SpinLock::new();
        let guard = lock.try_guard().expect("lock should be free");
        assert!(lock.try_guard().is_none());
        drop(guard);
    }

    #[test]
    fn spin_lock_try_guard_restores_on_failure() {
        let lock = SpinLock::new();
        let guard = lock.guard();
        assert!(lock.try_guard().is_none());
        drop(guard);
    }
}
