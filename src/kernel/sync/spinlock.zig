//! Ticket SpinLock for SMP synchronization.
//!
//! Fair (FIFO) spinlock that prevents starvation. Each acquirer takes a ticket
//! and waits until their number is served. Uses architecture-specific power
//! optimization: ARM64 sleeps with WFE, RISC-V polls with pause hints.
//!
//! Layout: single 32-bit word with owner (low 16) and next (high 16), enabling
//! atomic operations on entire lock state. Matches Linux/Jailhouse approach.

const std = @import("std");
const hal = @import("../hal/hal.zig");
const cpu = @import("../hal/cpu.zig");

/// Ticket spinlock with FIFO acquisition order.
///
/// ```
/// // Interrupt-safe (preferred for locks accessed by interrupt handlers):
/// const held = lock.guard();
/// defer held.release();
///
/// // Raw (when interrupts already disabled):
/// lock.acquire();
/// defer lock.release();
///
/// // Non-blocking attempt (returns immediately if lock held):
/// if (lock.tryAcquire()) {
///     defer lock.release();
///     // ... critical section ...
/// }
/// ```
pub const SpinLock = struct {
    /// Packed tickets: owner (bits 0-15), next (bits 16-31).
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const Self = @This();
    const TICKET_SHIFT = 16;

    /// Acquire lock, spinning until obtained.
    pub fn acquire(self: *Self) void {
        // Atomically increment next ticket (upper 16 bits), get old state.
        const old = self.state.fetchAdd(1 << TICKET_SHIFT, .monotonic);
        const my_ticket: u16 = @truncate(old >> TICKET_SHIFT);

        // Fast path: lock was free (owner == my_ticket).
        if (@as(u16, @truncate(old)) == my_ticket) return;

        // Slow path: spin until owner matches our ticket.
        cpu.spinWaitEq16(&self.state.raw, my_ticket);
    }

    /// Release lock, waking next waiter.
    pub fn release(self: *Self) void {
        // Increment owner (lower 16 bits).
        _ = self.state.fetchAdd(1, .release);
    }

    /// Try to acquire lock without blocking. Returns true if acquired.
    pub fn tryAcquire(self: *Self) bool {
        const current = self.state.load(.monotonic);
        const owner: u16 = @truncate(current);
        const next: u16 = @truncate(current >> TICKET_SHIFT);

        // Lock is free when owner == next.
        if (owner != next) return false;

        // Try to atomically increment next ticket while owner unchanged.
        const new = current +% (1 << TICKET_SHIFT);
        return self.state.cmpxchgWeak(current, new, .acquire, .monotonic) == null;
    }

    /// Acquire with interrupt safety. Returns guard that restores state on release.
    pub fn guard(self: *Self) Held {
        const was_enabled = hal.trap.disableInterrupts();
        self.acquire();
        return .{ .lock = self, .irq_was_enabled = was_enabled };
    }

    pub const Held = struct {
        lock: *SpinLock,
        irq_was_enabled: bool,

        pub fn release(self: Held) void {
            self.lock.release();
            if (self.irq_was_enabled) hal.trap.enableInterrupts();
        }
    };
};

test "SpinLock size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(SpinLock));
}

test "SpinLock initial state" {
    const lock = SpinLock{};
    try std.testing.expectEqual(@as(u32, 0), lock.state.load(.monotonic));
}

test "SpinLock acquire and release" {
    var lock = SpinLock{};

    lock.acquire();
    // next=1, owner=0
    try std.testing.expectEqual(@as(u32, 1 << 16), lock.state.load(.monotonic));

    lock.release();
    // next=1, owner=1
    try std.testing.expectEqual(@as(u32, (1 << 16) | 1), lock.state.load(.monotonic));
}

test "SpinLock multiple cycles" {
    var lock = SpinLock{};

    lock.acquire();
    lock.release();
    lock.acquire();
    lock.release();
    lock.acquire();
    lock.release();

    // next=3, owner=3
    try std.testing.expectEqual(@as(u32, (3 << 16) | 3), lock.state.load(.monotonic));
}

test "SpinLock tryAcquire succeeds when free" {
    var lock = SpinLock{};

    try std.testing.expect(lock.tryAcquire());
    // next=1, owner=0 (lock held)
    try std.testing.expectEqual(@as(u32, 1 << 16), lock.state.load(.monotonic));

    lock.release();
}

test "SpinLock tryAcquire fails when held" {
    var lock = SpinLock{};

    lock.acquire();
    // Lock is held, tryAcquire should fail
    try std.testing.expect(!lock.tryAcquire());
    // State unchanged (still next=1, owner=0)
    try std.testing.expectEqual(@as(u32, 1 << 16), lock.state.load(.monotonic));

    lock.release();
}
