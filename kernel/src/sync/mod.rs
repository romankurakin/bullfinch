//! Kernel synchronization primitives.
//!
//! Spin locks are usable before blocking is available and inside interrupt
//! paths. Keep critical sections short and never hold them across operations
//! that can block.

use core::{
    cell::UnsafeCell,
    ops::{Deref, DerefMut},
    sync::atomic::{AtomicBool, AtomicU16, Ordering},
};

#[cfg(test)]
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
    owner: AtomicU16,
    next: AtomicU16,
}

const _: () = assert!(core::mem::size_of::<TicketLock>() == core::mem::size_of::<u32>());

impl TicketLock {
    const fn new() -> Self {
        Self {
            owner: AtomicU16::new(0),
            next: AtomicU16::new(0),
        }
    }

    fn acquire(&self) {
        // Wrapping is valid while fewer than 2^16 tickets are outstanding. The
        // acquire load of `owner` pairs with the previous holder's release.
        let ticket = self.next.fetch_add(1, Ordering::Relaxed);
        while self.owner.load(Ordering::Acquire) != ticket {
            crate::cpu::spin_wait();
        }
    }

    fn try_acquire(&self) -> bool {
        let owner = self.owner.load(Ordering::Acquire);
        let next = self.next.load(Ordering::Relaxed);
        if owner != next {
            return false;
        }
        // The owner load above provides the acquire edge; this CAS only claims
        // the uncontended ticket against competing acquirers.
        self.next
            .compare_exchange(
                next,
                next.wrapping_add(1),
                Ordering::Relaxed,
                Ordering::Relaxed,
            )
            .is_ok()
    }

    fn release(&self) {
        let owner = self.owner.load(Ordering::Relaxed);
        #[cfg(debug_assertions)]
        {
            // Unlocking an unlocked ticket lock is a caller-side lock invariant bug.
            assert_ne!(
                owner,
                self.next.load(Ordering::Relaxed),
                "ticket: release called when lock is not held"
            );
        }
        // Only the current lock holder writes `owner`, so release is one
        // halfword store and cannot carry into the independently atomic queue.
        self.owner.store(owner.wrapping_add(1), Ordering::Release);
    }

    #[cfg(test)]
    fn raw(&self) -> u32 {
        (u32::from(self.next.load(Ordering::Relaxed)) << TICKET_SHIFT)
            | u32::from(self.owner.load(Ordering::Relaxed))
    }
}

impl Default for TicketLock {
    fn default() -> Self {
        Self::new()
    }
}

pub struct SpinLock {
    inner: TicketLock,
    #[cfg(debug_assertions)]
    // INVARIANT: This is debug state, not owner tracking. It must not gate
    // acquisition because another CPU can hold the lock while this CPU waits.
    held: AtomicBool,
}

impl SpinLock {
    pub const fn new() -> Self {
        Self {
            inner: TicketLock::new(),
            #[cfg(debug_assertions)]
            held: AtomicBool::new(false),
        }
    }

    fn lock(&self) {
        self.inner.acquire();
        #[cfg(debug_assertions)]
        self.held.store(true, Ordering::Relaxed);
    }

    fn try_lock(&self) -> bool {
        let acquired = self.inner.try_acquire();
        if acquired {
            #[cfg(debug_assertions)]
            self.held.store(true, Ordering::Relaxed);
        }
        acquired
    }

    fn unlock(&self) {
        #[cfg(debug_assertions)]
        {
            // Debug ownership tracking catches unmatched unlocks before touching the ticket.
            assert!(
                self.held.load(Ordering::Relaxed),
                "spinlock: release called when lock is not held"
            );
            self.held.store(false, Ordering::Relaxed);
        }
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

/// Mutable global state protected by a spin lock.
pub struct Locked<T> {
    lock: SpinLock,
    value: UnsafeCell<T>,
}

// SAFETY: `Locked` gives access to `T` only while its spin lock is held. Moving
// `T` between CPUs through the guard is sound when `T: Send`.
unsafe impl<T: Send> Sync for Locked<T> {}

impl<T> Locked<T> {
    pub const fn new(value: T) -> Self {
        Self {
            lock: SpinLock::new(),
            value: UnsafeCell::new(value),
        }
    }

    pub fn lock(&self) -> LockedGuard<'_, T> {
        LockedGuard {
            _guard: self.lock.guard(),
            value: self.value.get(),
        }
    }

    pub fn try_lock(&self) -> Option<LockedGuard<'_, T>> {
        Some(LockedGuard {
            _guard: self.lock.try_guard()?,
            value: self.value.get(),
        })
    }
}

#[must_use = "dropping the guard releases the lock"]
pub struct LockedGuard<'a, T> {
    _guard: SpinLockGuard<'a>,
    value: *mut T,
}

impl<T> Deref for LockedGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        // SAFETY: The guard holds the lock, and shared access does not mutate `T`.
        unsafe { &*self.value }
    }
}

impl<T> DerefMut for LockedGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        // SAFETY: The guard holds the lock, giving exclusive mutable access.
        unsafe { &mut *self.value }
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
    fn ticket_lock_wrap_does_not_advance_next_twice() {
        let lock = TicketLock::new();
        lock.owner.store(u16::MAX, Ordering::Relaxed);
        lock.next.store(u16::MAX, Ordering::Relaxed);

        lock.acquire();
        assert_eq!(lock.raw(), u32::from(u16::MAX));
        lock.release();
        assert_eq!(lock.raw(), 0);

        assert!(lock.try_acquire());
        lock.release();
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

    #[test]
    fn locked_serializes_mutation() {
        let locked = Locked::new(1usize);
        {
            let mut guard = locked.lock();
            *guard += 1;
        }
        assert_eq!(*locked.lock(), 2);
    }
}
