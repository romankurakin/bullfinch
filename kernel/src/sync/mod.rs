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
/// One `try_once` caller claims the step and returns true. Other calls return
/// false. The flag records the claim, not the completion of initialization.
/// Readers cannot use `is_done` to decide whether initialized data is ready.
/// If the winner publishes shared data, use a primitive that tracks completion
/// and defines when readers can access that data.
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

// A waiting caller takes a ticket from `next`, then waits for `owner` to match.
// Releasing the lock advances `owner`, admitting the next ticket in order.
// The acquire/release pair below makes the previous holder's writes visible
// to the next holder; ticket allocation alone does not publish those writes.
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
        // The Acquire load of `owner` observes the previous holder's writes.
        // This compare-and-swap only claims the next ticket against competing
        // callers, so it can use Relaxed ordering.
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
            assert_ne!(
                owner,
                self.next.load(Ordering::Relaxed),
                "ticket: release called when lock is not held"
            );
        }
        // Only the current holder writes `owner`. Incrementing this separate
        // 16-bit counter cannot carry into `next` when `owner` wraps.
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

/// A ticket lock that disables local interrupts before acquiring the lock.
///
/// This prevents an interrupt handler on the same CPU from waiting for a lock
/// held by the interrupted code. The guard releases the lock before restoring
/// the previous interrupt state. Do not block, switch threads, or acquire the
/// same lock again while holding its guard.
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
///
/// A guard gives exclusive access to the value and keeps local interrupts
/// disabled. The restrictions on [`SpinLock`] guards apply here too.
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
