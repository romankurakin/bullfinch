//! Trap result types.
//!
//! Handlers return TrapResult so outcomes are explicit.
//!
//! TODO(scheduler): Add yield variant for context switching.
//! TODO(signals): Add signal delivery variant.

const std = @import("std");

/// Outcome of trap handling.
pub const TrapResult = union(enum) {
    /// Return to interrupted code at saved PC. Most common outcome for handled
    /// interrupts (timer tick, device IRQ).
    handled,

    /// Return to interrupted code, but trap frame was modified. Handler changed
    /// PC, registers, or other state. Used for syscall return values.
    handled_modified,

    /// Kernel bug or unrecoverable error. Handler provides panic message.
    panic: []const u8,

    // TODO(scheduler): Add yield variant when scheduler exists
    // yield: YieldReason,

    // TODO(signals): Add signal delivery variant
    // signal: SignalInfo,

    // TODO(process): Add terminate variant for user faults
    // terminate: TerminateInfo,
};

test "TrapResult.handled is a valid tag" {
    const result: TrapResult = .handled;
    try std.testing.expect(result == .handled);
}

test "TrapResult.panic carries message" {
    const result: TrapResult = .{ .panic = "test panic" };
    switch (result) {
        .panic => |msg| try std.testing.expectEqualStrings("test panic", msg),
        else => return error.UnexpectedResult,
    }
}
