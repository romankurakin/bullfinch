//! RISC-V Entropy Sources.
//!
//! Collects entropy from hardware sources for seeding PRNGs and allocator cookies.
//! Tries Zkr seed CSR (hardware RNG) first, falls back to timer.
//!
//! See RISC-V Unprivileged Specification, 31.5 (Entropy Source).

const std = @import("std");
const hwinfo = @import("../../hwinfo/hwinfo.zig");

/// Seed CSR status codes (bits 31:30). ES16 means 16 bits of entropy ready.
const OPST_ES16: u32 = 0b01;

/// Cached Zkr availability.
const HwRngState = enum(u8) { unknown, available, unavailable };
var hwrng_state = std.atomic.Value(HwRngState).init(.unknown);

/// Collect entropy. Tries hardware RNG, falls back to timer.
pub fn collect(addr_hint: usize) u64 {
    if (hasHwRng()) {
        var entropy: u64 = 0;
        var got: usize = 0;
        for (0..16) |_| {
            if (tryHwRng()) |s| {
                entropy = (entropy << 16) | s;
                got += 1;
                if (got == 4) return entropy ^ readTimer();
            }
        }
    }

    const timer = readTimer();
    return timer ^ @as(u64, @intCast(addr_hint)) ^ (timer >> 17);
}

/// Collect with additional mixing for higher quality.
pub fn collectMixed(addr_hint: usize) u64 {
    var entropy = collect(addr_hint);

    for (0..3) |_| {
        if (hasHwRng()) {
            if (tryHwRng()) |s| {
                entropy ^= @as(u64, s) << 48;
            }
        }
        entropy ^= readTimer();
        entropy = rotl(entropy, 13);
    }

    return entropy;
}

fn hasHwRng() bool {
    const state = hwrng_state.load(.acquire);
    if (state != .unknown) return state == .available;

    // DTB reports Zkr availability from the first CPU node.
    const available = hwinfo.info.features.riscv.has_zkr;
    const result: HwRngState = if (available) .available else .unavailable;
    hwrng_state.store(result, .release);
    return result == .available;
}

/// Try reading seed CSR. Returns null if unavailable or no entropy ready.
fn tryHwRng() ?u16 {
    if (!hasHwRng()) return null;

    const result: u32 = asm volatile ("csrr %[val], 0x015"
        : [val] "=r" (-> u32),
    );

    if (result >> 30 == OPST_ES16) {
        return @truncate(result);
    }
    return null;
}

/// Read mtime via rdtime. Runs from power-on, no init needed.
inline fn readTimer() u64 {
    return asm volatile ("rdtime %[t]"
        : [t] "=r" (-> u64),
    );
}

fn rotl(x: u64, comptime r: u6) u64 {
    return (x << r) | (x >> @as(u6, 64 - @as(u7, r)));
}
