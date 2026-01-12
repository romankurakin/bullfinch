//! One-shot Synchronization Primitive.
//!
//! Atomic flag ensuring an action happens exactly once, even under
//! concurrent access. Designed for panic guards and simple "do once" flags.
//!
//! Uses acquire semantics only. If the "winner" writes shared data that
//! "losers" will read, you need additional synchronization. For lazy
//! initialization with shared data, use release/acquire pairs.

const std = @import("std");

/// Atomic one-shot flag. Returns true only on the first call to `tryOnce()`.
///
/// Usage (panic guard - no shared data):
/// ```
/// var panic_once: Once = .{};
///
/// fn handlePanic() void {
///     if (!panic_once.tryOnce()) return; // Already panicking
///     // ... panic handling ...
/// }
/// ```
pub const Once = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Returns true if this is the first call, false otherwise.
    /// Thread-safe: exactly one caller will receive true.
    pub fn tryOnce(self: *Once) bool {
        return !self.done.swap(true, .acquire);
    }

    /// Returns true if `tryOnce()` has already returned true to some caller.
    pub fn isDone(self: *Once) bool {
        return self.done.load(.acquire);
    }
};

test "Once tryOnce returns true only first time" {
    var once = Once{};

    try std.testing.expect(once.tryOnce());
    try std.testing.expect(!once.tryOnce());
    try std.testing.expect(!once.tryOnce());
}

test "Once isDone tracks state" {
    var once = Once{};

    try std.testing.expect(!once.isDone());
    _ = once.tryOnce();
    try std.testing.expect(once.isDone());
}

test "Once size is minimal" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Once));
}
