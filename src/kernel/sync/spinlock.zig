//! Kernel SpinLock.
//!
//! Wraps TicketLock with architecture-specific power-efficient spinning and
//! interrupt-safe guard() for kernel use. Uses WFE on ARM64, pause hints on RISC-V.
//!
//! Spinlocks busy-wait instead of blocking, making them usable before the scheduler
//! exists and inside interrupt handlers where blocking is impossible. Critical
//! sections must be short and never hold across blocking operations.
//!
//! ```
//! // Interrupt-safe (preferred):
//! const held = lock.guard();
//! defer held.release();
//!
//! // Raw (when interrupts already disabled):
//! lock.acquire();
//! defer lock.release();
//! ```
//!
//! TODO(smp): Add per-CPU magazine cache for lock-free fast path.
//! See Bonwick, "Magazines and Vmem" (USENIX 2001).

const std = @import("std");
const cpu = @import("../hal/cpu.zig");
const ticket = @import("ticket.zig");

/// Kernel spinlock with power-efficient spinning and interrupt safety.
pub const SpinLock = struct {
    inner: Inner = .{},

    const Self = @This();
    const Inner = ticket.TicketLock(cpu.spinWaitEq16);

    /// Acquire lock, spinning until obtained.
    pub fn acquire(self: *Self) void {
        self.inner.acquire();
    }

    /// Release lock.
    pub fn release(self: *Self) void {
        self.inner.release();
    }

    /// Try to acquire lock without blocking.
    pub fn tryAcquire(self: *Self) bool {
        return self.inner.tryAcquire();
    }

    /// Acquire with interrupt safety. Disables interrupts before acquiring,
    /// restores previous state on release.
    pub fn guard(self: *Self) Held {
        const was_enabled = cpu.disableInterrupts();
        self.inner.acquire();
        return .{ .lock = self, .irq_was_enabled = was_enabled };
    }

    /// RAII guard returned by guard(). Releases lock and restores interrupt state.
    pub const Held = struct {
        lock: *SpinLock,
        irq_was_enabled: bool,

        pub fn release(self: Held) void {
            self.lock.inner.release();
            if (self.irq_was_enabled) cpu.enableInterrupts();
        }
    };
};
