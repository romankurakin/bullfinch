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
//! Debug builds detect double-release and recursive acquire attempts.
//!
//! TODO(smp): Add per-CPU magazine cache for lock-free fast path.
//! TODO(smp): Track lock owner CPU in debug mode (not just a boolean held flag).
//! See Bonwick, "Magazines and Vmem" (USENIX 2001).

const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("../hal/cpu.zig");
const ticket = @import("ticket.zig");

/// Enable extra validation in debug builds.
const debug_kernel = builtin.mode == .Debug;

const panic_msg = struct {
    const RELEASE_UNHELD = "spinlock: release called on unheld lock";
    const RECURSIVE_ACQUIRE = "spinlock: recursive acquire (would deadlock)";
};

/// Kernel spinlock with power-efficient spinning and interrupt safety.
pub const SpinLock = struct {
    inner: Inner = .{},
    /// Debug-only: tracks if lock is held to detect misuse.
    held: if (debug_kernel) bool else void = if (debug_kernel) false else {},

    const Self = @This();
    const Inner = ticket.TicketLock(cpu.spinWaitEq16);

    /// Acquire lock, spinning until obtained.
    pub fn acquire(self: *Self) void {
        if (debug_kernel) {
            // Check before acquire - if already held, this would deadlock.
            // Catching it here gives a clear panic instead of a hang.
            if (self.held) @panic(panic_msg.RECURSIVE_ACQUIRE);
        }
        self.inner.acquire();
        if (debug_kernel) self.held = true;
    }

    /// Release lock.
    pub fn release(self: *Self) void {
        if (debug_kernel) {
            if (!self.held) @panic(panic_msg.RELEASE_UNHELD);
            self.held = false;
        }
        self.inner.release();
    }

    /// Try to acquire lock without blocking.
    pub fn tryAcquire(self: *Self) bool {
        if (debug_kernel) {
            if (self.held) @panic(panic_msg.RECURSIVE_ACQUIRE);
        }
        const acquired = self.inner.tryAcquire();
        if (debug_kernel and acquired) self.held = true;
        return acquired;
    }

    /// Acquire with interrupt safety. Disables interrupts before acquiring,
    /// restores previous state on release.
    pub fn guard(self: *Self) Held {
        if (debug_kernel) {
            if (self.held) @panic(panic_msg.RECURSIVE_ACQUIRE);
        }
        const was_enabled = cpu.disableInterrupts();
        self.inner.acquire();
        if (debug_kernel) self.held = true;
        return .{ .lock = self, .irq_was_enabled = was_enabled };
    }

    /// RAII guard returned by guard(). Releases lock and restores interrupt state.
    pub const Held = struct {
        lock: *SpinLock,
        irq_was_enabled: bool,

        pub fn release(self: Held) void {
            if (debug_kernel) {
                if (!self.lock.held) @panic(panic_msg.RELEASE_UNHELD);
                self.lock.held = false;
            }
            self.lock.inner.release();
            if (self.irq_was_enabled) cpu.enableInterrupts();
        }

        /// Release lock but keep interrupts disabled.
        pub fn releaseNoIrqRestore(self: Held) void {
            if (debug_kernel) {
                if (!self.lock.held) @panic(panic_msg.RELEASE_UNHELD);
                self.lock.held = false;
            }
            self.lock.inner.release();
        }
    };
};
