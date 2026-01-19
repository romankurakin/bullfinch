//! Kernel Synchronization Primitives.

pub const ticket = @import("ticket.zig");
pub const SpinLock = @import("spinlock.zig").SpinLock;
pub const Once = @import("once.zig").Once;

test {
    _ = @import("ticket.zig");
    _ = @import("once.zig");
}
