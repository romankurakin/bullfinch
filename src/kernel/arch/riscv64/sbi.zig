//! SBI ecall wrappers for OpenSBI firmware.

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

pub fn legacyConsolePutchar(byte: u8) void {
    _ = call(0x01, 0, byte, 0, 0) catch @panic("SBI console putchar failed");
}

/// Check if an SBI return value indicates an error (negative when interpreted as signed).
pub fn isError(ret: usize) bool {
    return @as(isize, @bitCast(ret)) < 0;
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
