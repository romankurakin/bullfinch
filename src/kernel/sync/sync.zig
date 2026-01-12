//! Kernel Synchronization Primitives.
//!
//! Provides low-level synchronization for SMP-safe kernel code.
//! All primitives are designed for kernel context (no blocking, spin-based).

pub const SpinLock = @import("spinlock.zig").SpinLock;
pub const Once = @import("once.zig").Once;

test {
    _ = @import("spinlock.zig");
    _ = @import("once.zig");
}
