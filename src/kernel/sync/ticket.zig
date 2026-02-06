//! Ticket Lock Algorithm.
//!
//! FIFO lock: acquirers take tickets and wait their turn. Prevents starvation.
//! No HAL dependencies — portable and testable on any host. For interrupt-safe
//! kernel use, see SpinLock.
//!
//! - acquire / release: O(1)
//! - tryAcquire: O(1)
//!
//! Debug builds verify release is only called when lock is held.
//!
//! TODO(smp): Revisit acquire ordering for ticket fast path when SMP is enabled.
//! TODO(smp): Formalize SpinWaitFn memory-order contract (acquire on success).
//!
//! ```
//! var lock = DefaultTicketLock{};
//! lock.acquire();
//! defer lock.release();
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Enable extra validation in debug builds.
const debug_kernel = builtin.mode == .Debug;

const panic_msg = struct {
    const RELEASE_UNHELD = "ticket: release called when lock not held";
};

/// Spin wait function type. Spins until low 16 bits of value at `ptr` equals `expected`.
pub const SpinWaitFn = *const fn (ptr: *u32, expected: u16) void;

/// Default spin wait: simple busy-loop polling.
fn defaultSpinWait(ptr: *u32, expected: u16) void {
    while (true) {
        const current: u16 = @truncate(@atomicLoad(u32, ptr, .monotonic));
        if (current == expected) return;
        std.atomic.spinLoopHint();
    }
}

/// Ticket lock with FIFO acquisition order.
///
/// Generic over spin wait function to allow architecture-specific power
/// optimization (WFE on ARM64, pause on x86) while keeping tests portable.
pub fn TicketLock(comptime spin_wait: SpinWaitFn) type {
    return struct {
        /// Packed tickets: owner (bits 0-15), next (bits 16-31).
        state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        const Self = @This();
        const TICKET_SHIFT = 16;

        /// Acquire lock, spinning until obtained.
        pub fn acquire(self: *Self) void {
            const old = self.state.fetchAdd(1 << TICKET_SHIFT, .monotonic);
            const my_ticket: u16 = @truncate(old >> TICKET_SHIFT);
            const owner: u16 = @truncate(old);

            // Fast path: lock was free.
            if (owner == my_ticket) return;

            // Slow path: spin until owner matches our ticket.
            spin_wait(&self.state.raw, my_ticket);
        }

        /// Release lock, waking next waiter.
        pub fn release(self: *Self) void {
            if (debug_kernel) {
                // Verify lock is actually held (owner != next).
                const current = self.state.load(.monotonic);
                const owner: u16 = @truncate(current);
                const next: u16 = @truncate(current >> TICKET_SHIFT);
                if (owner == next) @panic(panic_msg.RELEASE_UNHELD);
            }
            _ = self.state.fetchAdd(1, .release);
        }

        /// Try to acquire lock without blocking.
        pub fn tryAcquire(self: *Self) bool {
            const current = self.state.load(.monotonic);
            const owner: u16 = @truncate(current);
            const next: u16 = @truncate(current >> TICKET_SHIFT);

            if (owner != next) return false;

            const new = current +% (1 << TICKET_SHIFT);
            return self.state.cmpxchgWeak(current, new, .acquire, .monotonic) == null;
        }
    };
}

/// Default ticket lock using simple spin wait. Portable, suitable for tests.
pub const DefaultTicketLock = TicketLock(defaultSpinWait);

test "keeps TicketLock size at 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(DefaultTicketLock));
}

test "starts TicketLock in initial state" {
    const lock = DefaultTicketLock{};
    try std.testing.expectEqual(@as(u32, 0), lock.state.load(.monotonic));
}

test "acquires and releases TicketLock" {
    var lock = DefaultTicketLock{};

    lock.acquire();
    try std.testing.expectEqual(@as(u32, 1 << 16), lock.state.load(.monotonic));

    lock.release();
    try std.testing.expectEqual(@as(u32, (1 << 16) | 1), lock.state.load(.monotonic));
}

test "handles multiple TicketLock cycles" {
    var lock = DefaultTicketLock{};

    lock.acquire();
    lock.release();
    lock.acquire();
    lock.release();
    lock.acquire();
    lock.release();

    try std.testing.expectEqual(@as(u32, (3 << 16) | 3), lock.state.load(.monotonic));
}

test "succeeds TicketLock.tryAcquire when free" {
    var lock = DefaultTicketLock{};

    try std.testing.expect(lock.tryAcquire());
    try std.testing.expectEqual(@as(u32, 1 << 16), lock.state.load(.monotonic));

    lock.release();
}

test "fails TicketLock.tryAcquire when held" {
    var lock = DefaultTicketLock{};

    lock.acquire();
    try std.testing.expect(!lock.tryAcquire());
    try std.testing.expectEqual(@as(u32, 1 << 16), lock.state.load(.monotonic));

    lock.release();
}
