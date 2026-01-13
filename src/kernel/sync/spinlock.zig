//! Ticket SpinLock for SMP Synchronization.
//!
//! A fair (FIFO) spinlock that prevents starvation under contention.
//! Each acquirer takes a ticket and waits until their number is called.
//!
//! Two acquisition modes:
//!
//! - guard(): Disables interrupts, acquires lock, restores on release.
//!   Use when interrupt handlers might need this lock. Prevents deadlock
//!   where: thread holds lock → interrupt fires → handler spins forever.
//!
//! - acquire()/release(): Raw lock operations without interrupt handling.
//!   Use only when interrupts are already disabled or when the lock is
//!   never accessed from interrupt context.
//!
//! Memory ordering:
//! - acquire: load with .acquire ensures subsequent reads see prior writes
//! - release: fetchAdd with .release ensures prior writes visible to next acquirer

const std = @import("std");
const hal = @import("../hal/hal.zig");

/// Ticket spinlock guaranteeing FIFO acquisition order.
///
/// ```
/// // Interrupt-safe (use for locks touched by interrupt handlers):
/// const held = lock.guard();
/// defer held.release();
///
/// // Raw (use only when interrupts already disabled):
/// lock.acquire();
/// defer lock.release();
/// ```
pub const SpinLock = struct {
    /// Next ticket number to be dispensed.
    next_ticket: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Ticket number currently being served.
    now_serving: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const Self = @This();

    /// Acquire the lock, spinning until obtained.
    /// Does NOT disable interrupts - use guard() for interrupt-safe locking.
    pub fn acquire(self: *Self) void {
        const my_ticket = self.next_ticket.fetchAdd(1, .monotonic);
        while (self.now_serving.load(.acquire) != my_ticket) {
            std.atomic.spinLoopHint();
        }
    }

    /// Release the lock. Must only be called by the current holder.
    pub fn release(self: *Self) void {
        _ = self.now_serving.fetchAdd(1, .release);
    }

    /// Acquire lock with interrupt safety. Disables interrupts, acquires lock,
    /// returns guard that restores interrupts on release.
    pub fn guard(self: *Self) Held {
        const irq_was_enabled = hal.trap.disableInterrupts();
        self.acquire();
        return Held{ .lock = self, .irq_was_enabled = irq_was_enabled };
    }

    pub const Held = struct {
        lock: *SpinLock,
        irq_was_enabled: bool,

        pub fn release(self: Held) void {
            self.lock.release();
            if (self.irq_was_enabled) {
                hal.trap.enableInterrupts();
            }
        }
    };
};

test "SpinLock initial state" {
    var lock = SpinLock{};
    try std.testing.expectEqual(@as(u32, 0), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), lock.now_serving.load(.monotonic));
}

test "SpinLock acquire and release" {
    var lock = SpinLock{};

    lock.acquire();
    try std.testing.expectEqual(@as(u32, 1), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), lock.now_serving.load(.monotonic));

    lock.release();
    try std.testing.expectEqual(@as(u32, 1), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), lock.now_serving.load(.monotonic));
}

test "SpinLock multiple acquire/release cycles" {
    var lock = SpinLock{};

    lock.acquire();
    lock.release();
    try std.testing.expectEqual(@as(u32, 1), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), lock.now_serving.load(.monotonic));

    lock.acquire();
    lock.release();
    try std.testing.expectEqual(@as(u32, 2), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), lock.now_serving.load(.monotonic));

    lock.acquire();
    lock.release();
    try std.testing.expectEqual(@as(u32, 3), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), lock.now_serving.load(.monotonic));
}

test "SpinLock size is small" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SpinLock));
}

test "Held size includes interrupt state" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SpinLock.Held));
}
