//! Trap Formatting Utilities.
//!
//! Lock-free formatting helpers for panic messages. These avoid std.fmt to work
//! in panic context where allocators and locks are unavailable.

/// Format a 64-bit value as hexadecimal (16 characters, no prefix).
pub fn formatHex(val: u64) [16]u8 {
    const hex_chars = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        const nibble: usize = @truncate(v & 0xF);
        buf[i] = hex_chars[nibble];
        v >>= 4;
    }
    return buf;
}

/// Format a decimal number. Returns buffer and length of valid data.
pub fn formatDecimal(val: usize) struct { buf: [20]u8, len: usize } {
    var buf: [20]u8 = undefined;
    var v = val;
    var i: usize = buf.len;

    if (v == 0) {
        var result: [20]u8 = undefined;
        result[0] = '0';
        return .{ .buf = result, .len = 1 };
    }

    while (v > 0) : (i -= 1) {
        const digit: u8 = @truncate('0' + (v % 10));
        buf[i - 1] = digit;
        v /= 10;
    }

    const len = buf.len - i;
    var result: [20]u8 = undefined;
    for (0..len) |j| {
        result[j] = buf[i + j];
    }
    return .{ .buf = result, .len = len };
}

test "formatHex produces correct output" {
    const std = @import("std");
    try std.testing.expectEqualStrings("0000000000000000", &formatHex(0));
    try std.testing.expectEqualStrings("000000000000000f", &formatHex(0xF));
    try std.testing.expectEqualStrings("00000000deadbeef", &formatHex(0xDEADBEEF));
    try std.testing.expectEqualStrings("ffffffffffffffff", &formatHex(0xFFFFFFFFFFFFFFFF));
}

test "formatDecimal produces correct output" {
    const std = @import("std");
    const zero = formatDecimal(0);
    try std.testing.expectEqualStrings("0", zero.buf[0..zero.len]);

    const small = formatDecimal(42);
    try std.testing.expectEqualStrings("42", small.buf[0..small.len]);

    const large = formatDecimal(1234567890);
    try std.testing.expectEqualStrings("1234567890", large.buf[0..large.len]);
}
