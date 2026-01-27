//! ARM64 Entropy Sources.
//!
//! Collects entropy from hardware sources for seeding PRNGs and allocator cookies.
//! Tries RNDR instruction (hardware RNG) first, falls back to physical timer.
//!
//! See ARM Architecture Reference Manual, K12 (Random Number Generation).

const std = @import("std");

/// ID_AA64ISAR0_EL1.RNDR field (bits 63:60). Value >= 1 means RNDR available.
const RNDR_SHIFT = 60;

/// Cached RNDR availability.
const HwRngState = enum(u8) { unknown, available, unavailable };
var hwrng_state = std.atomic.Value(HwRngState).init(.unknown);

/// Collect entropy. Tries hardware RNG, falls back to timer.
pub fn collect(addr_hint: usize) u64 {
    if (tryHwRng()) |hw| {
        return hw ^ readTimer();
    }
    const timer = readTimer();
    return timer ^ @as(u64, @intCast(addr_hint)) ^ (timer >> 17);
}

/// Collect with additional mixing for higher quality.
pub fn collectMixed(addr_hint: usize) u64 {
    var entropy = collect(addr_hint);

    if (hasHwRng()) {
        for (0..3) |_| {
            if (tryHwRng()) |sample| {
                entropy ^= sample;
                entropy = rotl(entropy, 13);
            }
        }
    }

    return entropy ^ readTimer();
}

fn hasHwRng() bool {
    const state = hwrng_state.load(.acquire);
    if (state != .unknown) return state == .available;

    const isar0 = asm volatile ("mrs %[val], id_aa64isar0_el1"
        : [val] "=r" (-> u64),
    );
    const available = (isar0 >> RNDR_SHIFT) & 0xF >= 1;
    const result: HwRngState = if (available) .available else .unavailable;
    hwrng_state.store(result, .release);
    return result == .available;
}

/// Try RNDR instruction. Returns null if unavailable or entropy exhausted.
fn tryHwRng() ?u64 {
    if (!hasHwRng()) return null;

    var value: u64 = undefined;
    var failed: u64 = undefined;

    // RNDR sets NZCV.Z on failure (no entropy available).
    // s3_3_c2_c4_0 is the RNDR system register encoding.
    asm volatile (
        \\mrs %[val], s3_3_c2_c4_0
        \\cset %[fail], eq
        : [val] "=r" (value),
          [fail] "=r" (failed),
    );

    return if (failed == 0) value else null;
}

/// Read physical timer counter. Runs from power-on, no init needed.
inline fn readTimer() u64 {
    return asm volatile ("mrs %[cnt], cntpct_el0"
        : [cnt] "=r" (-> u64),
    );
}

fn rotl(x: u64, comptime r: u6) u64 {
    return (x << r) | (x >> @as(u6, 64 - @as(u7, r)));
}
