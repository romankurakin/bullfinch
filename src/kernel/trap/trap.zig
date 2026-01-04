//! Common Trap Utilities.
//!
//! Formatting helpers for register dumps and trap messages.

/// Format a 64-bit value as hexadecimal (16 characters, no prefix).
pub fn formatHex(val: u64) [16]u8 {
    const hex_chars = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @truncate(v & 0xF))];
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
        buf[i - 1] = @as(u8, @truncate('0' + (v % 10)));
        v /= 10;
    }

    const len = buf.len - i;
    var result: [20]u8 = undefined;
    for (0..len) |j| {
        result[j] = buf[i + j];
    }
    return .{ .buf = result, .len = len };
}

/// Format a register name with padding to 7 characters.
pub fn formatRegName(name: []const u8) [7]u8 {
    var buf: [7]u8 = [_]u8{' '} ** 7;
    const copy_len = @min(name.len, 7);
    for (0..copy_len) |i| {
        buf[i] = name[i];
    }
    return buf;
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

test "formatRegName pads correctly" {
    const std = @import("std");
    try std.testing.expectEqualStrings("x0     ", &formatRegName("x0"));
    try std.testing.expectEqualStrings("sepc   ", &formatRegName("sepc"));
    try std.testing.expectEqualStrings("scause ", &formatRegName("scause"));
}
