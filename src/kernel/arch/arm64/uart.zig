//! PL011 UART driver for ARM64 platforms.
//! Documentation can be found at: https://developer.arm.com/documentation/ddi0183/latest/
//! Provides direct MMIO access to UART hardware for output. Callers supply base address.
//! Peripheral powers up disabled - must configure baud divisors and enable TX.

const UART_DR_OFFSET = 0x00;
const UART_FR_OFFSET = 0x18;
const UART_IBRD_OFFSET = 0x24;
const UART_FBRD_OFFSET = 0x28;
const UART_LCRH_OFFSET = 0x2C;
const UART_CR_OFFSET = 0x30;
const UART_ICR_OFFSET = 0x44;

const UART_FR_TXFF = 1 << 5;
const UART_FR_BUSY = 1 << 3;
const UART_CR_UARTEN = 1 << 0;
const UART_CR_TXE = 1 << 8;
const UART_LCRH_FEN = 1 << 4;
const UART_LCRH_WLEN_8 = 0b11 << 5;

pub const InitConfig = struct {
    uartclk_hz: u32 = 24_000_000,
    baud: u32 = 115_200,
};

pub const State = struct {
    initialized: bool = false,
};

// Volatile MMIO register accessors. Inline for performance, volatile for hardware ordering.
inline fn reg32(base: usize, comptime offset: usize) *volatile u32 {
    return @as(*volatile u32, @ptrFromInt(base + offset));
}

inline fn reg8(base: usize, comptime offset: usize) *volatile u8 {
    return @as(*volatile u8, @ptrFromInt(base + offset));
}

// Compute baud rate divisors per PL011 spec. Uses u64 to prevent overflow.
pub fn computeDivisors(uartclk_hz: u32, baud: u32) struct { ibrd: u32, fbrd: u32 } {
    if (baud == 0) @panic("baud must be non-zero"); // Safety: avoid division by zero
    const denom = @as(u64, 16) * @as(u64, baud);
    const clk = @as(u64, uartclk_hz);
    const ibrd = clk / denom;
    const remainder = clk - denom * ibrd;
    const fbrd = (remainder * 64 + denom / 2) / denom; // Rounding for fractional part
    return .{ .ibrd = @intCast(ibrd), .fbrd = @intCast(fbrd) };
}

fn setBaud(base: usize, uartclk_hz: u32, baud: u32) void {
    const divs = computeDivisors(uartclk_hz, baud);
    reg32(base, UART_IBRD_OFFSET).* = divs.ibrd;
    reg32(base, UART_FBRD_OFFSET).* = divs.fbrd;
}

// Initialize PL011 UART with config. Disables during setup to avoid glitches.
// Waits for TX drain, clears interrupts, sets baud/8N1, enables TX only.
pub fn init(base: usize, state: *State, config: InitConfig) void {
    // Drain TX before disabling to prevent data loss. Safety critical.
    while ((reg32(base, UART_FR_OFFSET).* & UART_FR_BUSY) != 0) {}

    // Disable UART before config changes. Hardware requires this.
    reg32(base, UART_CR_OFFSET).* = 0;
    // Clear all interrupts to start clean.
    reg32(base, UART_ICR_OFFSET).* = 0x7FF;
    // Program baud rate from clock.
    setBaud(base, config.uartclk_hz, config.baud);
    // 8-bit words, FIFO enabled for buffering.
    reg32(base, UART_LCRH_OFFSET).* = UART_LCRH_WLEN_8 | UART_LCRH_FEN;

    // Enable UART and TX only
    reg32(base, UART_CR_OFFSET).* = UART_CR_UARTEN | UART_CR_TXE;
    // Readback ensures write completed on weakly ordered ARM64.
    _ = reg32(base, UART_CR_OFFSET).*;

    state.initialized = true;
}

pub fn initDefault(base: usize, state: *State) void {
    init(base, state, .{});
}

// Print string to UART. Requires explicit initialization.
pub fn print(base: usize, state: *State, s: []const u8) void {
    if (!state.initialized) @panic("UART not initialized");

    // Verify UART is actually enabled in hardware
    const cr = reg32(base, UART_CR_OFFSET).*;
    if ((cr & (UART_CR_UARTEN | UART_CR_TXE)) != (UART_CR_UARTEN | UART_CR_TXE)) {
        @panic("UART disabled in hardware");
    }

    for (s) |byte| {
        while ((reg32(base, UART_FR_OFFSET).* & UART_FR_TXFF) != 0) {} // Wait for space
        reg8(base, UART_DR_OFFSET).* = byte;
    }
}

test "computeDivisors typical baud rates" {
    const std = @import("std");
    const testing = std.testing;
    const cases = [_]struct {
        uartclk: u32,
        baud: u32,
        ibrd: u32,
        fbrd: u32,
    }{
        .{ .uartclk = 24_000_000, .baud = 115_200, .ibrd = 13, .fbrd = 1 },
        .{ .uartclk = 24_000_000, .baud = 9_600, .ibrd = 156, .fbrd = 16 },
        .{ .uartclk = 3_000_000, .baud = 115_200, .ibrd = 1, .fbrd = 40 },
    };

    for (cases) |case| {
        const divs = computeDivisors(case.uartclk, case.baud);
        try testing.expectEqual(case.ibrd, divs.ibrd);
        try testing.expectEqual(case.fbrd, divs.fbrd);
    }
}

test "computeDivisors handles rounding edge cases" {
    const std = @import("std");
    const testing = std.testing;
    const divs = computeDivisors(7_372_800, 115_200);
    try testing.expectEqual(@as(u32, 4), divs.ibrd);
    try testing.expectEqual(@as(u32, 0), divs.fbrd);

    const divs2 = computeDivisors(26_000_000, 115_200);
    try testing.expectEqual(@as(u32, 14), divs2.ibrd);
    try testing.expectEqual(@as(u32, 7), divs2.fbrd);
}
