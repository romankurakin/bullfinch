//! SBI (Supervisor Binary Interface) Wrappers.
//!
//! SBI is the interface between S-mode (kernel) and M-mode (OpenSBI firmware). It
//! provides services that require M-mode privilege: timer, IPI, console, power control.
//!
//! The ecall instruction traps to M-mode. Arguments go in a0-a2, extension ID in a7,
//! function ID in a6. Return value comes back in a0 (negative = error).
//!
//! We use the Timer Extension for scheduling and legacy console for early boot output.
//!
//! See RISC-V SBI Specification.

const panic_msg = struct {
    const PUTCHAR_FAILED = "SBI: console putchar failed";
    const SET_TIMER_FAILED = "SBI: set_timer failed";
};

const EXT_TIMER: usize = 0x54494D45; // "TIME"

/// SBI ecall with up to 3 arguments. Returns error if SBI returns negative value.
pub fn call(eid: usize, fid: usize, arg0: usize, arg1: usize, arg2: usize) !usize {
    var ret: usize = undefined;
    asm volatile ("ecall"
        : [ret] "={a0}" (ret),
        : [eid] "{a7}" (eid),
          [fid] "{a6}" (fid),
          [a0] "{a0}" (arg0),
          [a1] "{a1}" (arg1),
          [a2] "{a2}" (arg2),
    );

    if (isError(ret)) {
        return error.SBIError;
    }
    return ret;
}

/// Write a single character to the console using legacy SBI call.
pub fn legacyConsolePutchar(byte: u8) void {
    _ = call(0x01, 0, byte, 0, 0) catch @panic(panic_msg.PUTCHAR_FAILED);
}

/// Check if an SBI return value indicates an error (negative when interpreted as signed).
pub fn isError(ret: usize) bool {
    return @as(isize, @bitCast(ret)) < 0;
}

/// Set timer deadline using SBI Timer Extension.
/// Programs mtimecmp and clears any pending timer interrupt.
/// The interrupt fires when mtime >= stime_value.
pub fn setTimer(stime_value: u64) void {
    _ = call(EXT_TIMER, 0, stime_value, 0, 0) catch
        @panic(panic_msg.SET_TIMER_FAILED);
}

test "isError detects negative return values" {
    const std = @import("std");

    // Positive values are success
    try std.testing.expect(!isError(0));
    try std.testing.expect(!isError(1));
    try std.testing.expect(!isError(0x7FFFFFFFFFFFFFFF));

    // Negative values (high bit set) are errors
    try std.testing.expect(isError(@as(usize, @bitCast(@as(isize, -1)))));
    try std.testing.expect(isError(@as(usize, @bitCast(@as(isize, -2)))));
    try std.testing.expect(isError(0x8000000000000000)); // Most negative
    try std.testing.expect(isError(0xFFFFFFFFFFFFFFFF)); // -1
}
