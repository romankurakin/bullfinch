//! C standard library shim for freestanding targets.
//!
//! Provides libc functions required by C libs. In freestanding mode, no C
//! runtime is available, so we implement the subset manually.

const std = @import("std");

/// Copy n bytes from src to dest. Returns dest.
fn memcpy_impl(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    for (0..n) |i| {
        dest[i] = src[i];
    }
    return dest;
}
comptime {
    @export(&memcpy_impl, .{ .name = "memcpy", .linkage = .weak });
}

/// Fill n bytes of dest with byte value. Returns dest.
fn memset_impl(dest: [*]u8, val: c_int, n: usize) callconv(.c) [*]u8 {
    const unsigned: u32 = @bitCast(val);
    const byte: u8 = @truncate(unsigned);
    for (0..n) |i| {
        dest[i] = byte;
    }
    return dest;
}
comptime {
    @export(&memset_impl, .{ .name = "memset", .linkage = .weak });
}

/// Copy n bytes from src to dest, handling overlap. Returns dest.
fn memmove_impl(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    const d = @intFromPtr(dest);
    const s = @intFromPtr(src);
    if (d < s or d >= s + n) {
        // No overlap or dest is after src+n, forward copy
        for (0..n) |i| {
            dest[i] = src[i];
        }
    } else {
        // Overlap with dest > src, backward copy
        var i = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}
comptime {
    @export(&memmove_impl, .{ .name = "memmove", .linkage = .weak });
}

/// Compare n bytes. Returns <0, 0, or >0.
export fn memcmp(p1: [*]const u8, p2: [*]const u8, n: usize) c_int {
    const s1 = p1[0..n];
    const s2 = p2[0..n];
    for (s1, s2) |a, b| {
        if (a != b) return if (a < b) -1 else 1;
    }
    return 0;
}

/// Find first occurrence of byte in n bytes. Returns pointer or null.
export fn memchr(ptr: [*]const u8, value: c_int, n: usize) ?[*]const u8 {
    const unsigned: u32 = @bitCast(value);
    const byte: u8 = @truncate(unsigned);
    for (0..n) |i| {
        if (ptr[i] == byte) return ptr + i;
    }
    return null;
}

/// Return length of null-terminated string.
export fn strlen(s: [*:0]const u8) usize {
    return std.mem.len(s);
}

/// Compare up to n bytes of two strings. Returns <0, 0, or >0.
export fn strncmp(s1: [*]const u8, s2: [*]const u8, n: usize) c_int {
    for (0..n) |i| {
        const a = s1[i];
        const b = s2[i];
        if (a != b) return if (a < b) -1 else 1;
        if (a == 0) return 0;
    }
    return 0;
}

/// Find first occurrence of char in string. Returns pointer or null.
export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8 {
    const unsigned: u32 = @bitCast(c);
    const char: u8 = @truncate(unsigned);
    var ptr = s;
    while (true) {
        if (ptr[0] == char) return ptr;
        if (ptr[0] == 0) return null;
        ptr += 1;
    }
}

/// Find last occurrence of char in string. Returns pointer or null.
export fn strrchr(s: [*:0]const u8, c: c_int) ?[*:0]const u8 {
    const unsigned: u32 = @bitCast(c);
    const char: u8 = @truncate(unsigned);
    const len = std.mem.len(s);
    var i = len + 1; // Include null terminator check
    while (i > 0) : (i -= 1) {
        if (s[i - 1] == char) return @ptrCast(s + i - 1);
    }
    return null;
}

/// Return length of string, limited to maxlen.
export fn strnlen(s: [*]const u8, maxlen: usize) usize {
    for (0..maxlen) |i| {
        if (s[i] == 0) return i;
    }
    return maxlen;
}

/// Parse unsigned integer from string with auto base detection.
export fn strtoul(nptr: [*]const u8, endptr: ?*[*]const u8, base_arg: c_int) c_ulong {
    var p = nptr;
    var base: c_ulong = @intCast(base_arg);
    var negative = false;
    var any_digits = false;
    const max = std.math.maxInt(c_ulong);

    // Skip whitespace
    while (p[0] == ' ' or p[0] == '\t' or p[0] == '\n') p += 1;

    // Optional sign
    if (p[0] == '+' or p[0] == '-') {
        negative = p[0] == '-';
        p += 1;
    }

    // Handle base detection
    if (base == 0 or base == 16) {
        if (p[0] == '0' and (p[1] == 'x' or p[1] == 'X')) {
            base = 16;
            p += 2;
        } else if (base == 0) {
            base = if (p[0] == '0') 8 else 10;
        }
    }

    // Convert digits
    var result: c_ulong = 0;
    var overflow = false;
    while (true) {
        const c = p[0];
        const digit: c_ulong = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'z')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'Z')
            c - 'A' + 10
        else
            break;

        if (digit >= base) break;
        any_digits = true;
        if (!overflow) {
            if (result > (max - digit) / base) {
                overflow = true;
                result = max;
            } else {
                result = result * base + digit;
            }
        }
        p += 1;
    }

    if (endptr) |e| {
        e.* = if (any_digits) p else nptr;
    }
    if (overflow) return max;
    return if (negative) 0 -% result else result;
}

test "strtoul accepts optional sign prefix" {
    const plus = " +42";
    var end_plus: [*]const u8 = undefined;
    const plus_val = strtoul(plus.ptr, &end_plus, 10);
    try std.testing.expectEqual(@as(c_ulong, 42), plus_val);
    try std.testing.expectEqual(
        @as(usize, plus.len),
        @intFromPtr(end_plus) - @intFromPtr(plus.ptr),
    );

    const minus = "-1";
    var end_minus: [*]const u8 = undefined;
    const minus_val = strtoul(minus.ptr, &end_minus, 10);
    try std.testing.expectEqual(@as(c_ulong, 0) -% 1, minus_val);
    try std.testing.expectEqual(
        @as(usize, minus.len),
        @intFromPtr(end_minus) - @intFromPtr(minus.ptr),
    );
}

test "strtoul saturates on overflow" {
    const huge = "999999999999999999999999999999999999999999";
    var end: [*]const u8 = undefined;
    const value = strtoul(huge.ptr, &end, 10);
    try std.testing.expectEqual(std.math.maxInt(c_ulong), value);
    try std.testing.expectEqual(@as(usize, huge.len), @intFromPtr(end) - @intFromPtr(huge.ptr));
}

test "strtoul auto-detects base and stops at invalid digit" {
    const hex = "0x1fZ";
    var hex_end: [*]const u8 = undefined;
    const hex_val = strtoul(hex.ptr, &hex_end, 0);
    try std.testing.expectEqual(@as(c_ulong, 31), hex_val);
    try std.testing.expectEqual(@as(usize, 4), @intFromPtr(hex_end) - @intFromPtr(hex.ptr));

    const oct = "0779";
    var oct_end: [*]const u8 = undefined;
    const oct_val = strtoul(oct.ptr, &oct_end, 0);
    try std.testing.expectEqual(@as(c_ulong, 63), oct_val);
    try std.testing.expectEqual(@as(usize, 3), @intFromPtr(oct_end) - @intFromPtr(oct.ptr));
}

test "strtoul sets endptr to input when no conversion" {
    const no_digits = "   +x";
    var end1: [*]const u8 = undefined;
    const v1 = strtoul(no_digits.ptr, &end1, 10);
    try std.testing.expectEqual(@as(c_ulong, 0), v1);
    try std.testing.expectEqual(@intFromPtr(no_digits.ptr), @intFromPtr(end1));

    const no_hex_digits = "0x";
    var end2: [*]const u8 = undefined;
    const v2 = strtoul(no_hex_digits.ptr, &end2, 0);
    try std.testing.expectEqual(@as(c_ulong, 0), v2);
    try std.testing.expectEqual(@intFromPtr(no_hex_digits.ptr), @intFromPtr(end2));
}

test "memmove handles overlapping regions" {
    var buf = [_]u8{ 'a', 'b', 'c', 'd', 'e', 0 };
    _ = memmove_impl(buf[1..].ptr, buf[0..].ptr, 4);
    try std.testing.expectEqualSlices(u8, "aabcd", buf[0..5]);
}
