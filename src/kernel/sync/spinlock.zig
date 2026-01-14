//! Ticket SpinLock for SMP synchronization.
//!
//! Fair (FIFO) spinlock that prevents starvation. Each acquirer takes a ticket
//! and waits until their number is served. Uses architecture-specific power
//! optimization: ARM64 sleeps with WFE, RISC-V polls with pause hints.

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
/// ```
pub const SpinLock = struct {
    now_serving: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    next_ticket: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const Self = @This();

    /// Acquire lock, spinning until obtained.
    pub fn acquire(self: *Self) void {
        const my_ticket = self.next_ticket.fetchAdd(1, .monotonic);
        cpu.spinWaitEq(&self.now_serving.raw, my_ticket);
    }

    /// Release lock. Clears global monitor, generating events for WFE waiters.
    pub fn release(self: *Self) void {
        cpu.storeRelease(&self.now_serving.raw, self.now_serving.raw + 1);
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

test "SpinLock size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SpinLock));
}

test "SpinLock initial state" {
    const lock = SpinLock{};
    try std.testing.expectEqual(@as(u32, 0), lock.now_serving.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), lock.next_ticket.load(.monotonic));
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

test "SpinLock multiple cycles" {
    var lock = SpinLock{};

    lock.acquire();
    lock.release();
    lock.acquire();
    lock.release();
    lock.acquire();
    lock.release();

    try std.testing.expectEqual(@as(u32, 3), lock.next_ticket.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), lock.now_serving.load(.monotonic));
}
