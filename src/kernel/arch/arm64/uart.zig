//! PL011 UART driver for ARM64 - TX only, direct MMIO.
//! ARM's standard UART peripheral. Powers up disabled, requires baud rate config + enable.

// PL011 register offsets (byte offsets from base address)
const UART_DR_OFFSET = 0x00; // Data Register
const UART_FR_OFFSET = 0x18; // Flag Register
const UART_IBRD_OFFSET = 0x24; // Integer Baud Rate Divisor
const UART_FBRD_OFFSET = 0x28; // Fractional Baud Rate Divisor
const UART_LCRH_OFFSET = 0x2C; // Line Control Register
const UART_CR_OFFSET = 0x30; // Control Register
const UART_ICR_OFFSET = 0x44; // Interrupt Clear Register

const UART_FR_TXFF = 1 << 5; // TX FIFO Full
const UART_FR_BUSY = 1 << 3; // UART Busy

const UART_CR_UARTEN = 1 << 0; // UART Enable
const UART_CR_TXE = 1 << 8; // TX Enable

const UART_LCRH_FEN = 1 << 4; // FIFO Enable
const UART_LCRH_WLEN_8 = 0b11 << 5; // 8-bit word length

pub const InitConfig = struct {
    uartclk_hz: u32 = 24_000_000,
    baud: u32 = 115_200,
};

pub const State = struct {
    initialized: bool = false,
};

// MMIO access (volatile required for memory-mapped I/O)
inline fn reg32(base: usize, comptime offset: usize) *volatile u32 {
    return @as(*volatile u32, @ptrFromInt(base + offset));
}

inline fn reg8(base: usize, comptime offset: usize) *volatile u8 {
    return @as(*volatile u8, @ptrFromInt(base + offset));
}

inline fn waitTxFifo(base: usize) void {
    while ((reg32(base, UART_FR_OFFSET).* & UART_FR_TXFF) != 0) {}
}

inline fn writeData(base: usize, byte: u8) void {
    reg8(base, UART_DR_OFFSET).* = byte;
}

/// Compute PL011 baud rate divisors (16x oversampling: divisor = clk / (16 * baud)).
/// Returns IBRD (1-65535) and FBRD (0-63, 6-bit fraction). Uses u64 to prevent overflow.
pub fn computeDivisors(uartclk_hz: u32, baud: u32) struct { ibrd: u32, fbrd: u32 } {
    if (baud == 0) @panic("baud must be non-zero");

    const denom = @as(u64, 16) * @as(u64, baud);
    const clk = @as(u64, uartclk_hz);
    const ibrd = clk / denom;
    const remainder = clk - denom * ibrd;
    const fbrd = (remainder * 64 + denom / 2) / denom; // Round fractional part

    if (ibrd < 1 or ibrd > 65535) @panic("IBRD out of valid range 1-65535");
    if (fbrd > 63) @panic("FBRD out of valid range 0-63");

    return .{ .ibrd = @intCast(ibrd), .fbrd = @intCast(fbrd) };
}

fn setBaud(base: usize, uartclk_hz: u32, baud: u32) void {
    const divs = computeDivisors(uartclk_hz, baud);
    reg32(base, UART_IBRD_OFFSET).* = divs.ibrd;
    reg32(base, UART_FBRD_OFFSET).* = divs.fbrd;
}

/// Initialize UART (must disable, configure baud rate + line control, enable).
pub fn init(base: usize, state: *State, config: InitConfig) void {
    while ((reg32(base, UART_FR_OFFSET).* & UART_FR_BUSY) != 0) {} // Wait for TX to complete
    reg32(base, UART_CR_OFFSET).* = 0; // Disable UART for config
    reg32(base, UART_ICR_OFFSET).* = 0x7FF; // Clear interrupts

    setBaud(base, config.uartclk_hz, config.baud);
    reg32(base, UART_LCRH_OFFSET).* = UART_LCRH_WLEN_8 | UART_LCRH_FEN; // 8N1, FIFOs enabled

    reg32(base, UART_CR_OFFSET).* = UART_CR_UARTEN | UART_CR_TXE; // Enable UART + TX
    asm volatile ("dsb ish"); // Ensure enable write reaches hardware (weakly-ordered memory)

    state.initialized = true;
}

pub fn initDefault(base: usize, state: *State) void {
    init(base, state, .{});
}

pub fn print(base: usize, state: *State, s: []const u8) void {
    if (!state.initialized) @panic("UART not initialized");

    const cr = reg32(base, UART_CR_OFFSET).*;
    if ((cr & (UART_CR_UARTEN | UART_CR_TXE)) != (UART_CR_UARTEN | UART_CR_TXE)) {
        @panic("UART disabled in hardware");
    }

    for (s) |byte| {
        waitTxFifo(base);
        if (byte == '\n') {
            writeData(base, '\r');
            waitTxFifo(base);
        }
        writeData(base, byte);
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
        .{ .uartclk = 48_000_000, .baud = 115_200, .ibrd = 26, .fbrd = 3 },
        .{ .uartclk = 12_000_000, .baud = 9_600, .ibrd = 78, .fbrd = 8 },
        .{ .uartclk = 1_843_200, .baud = 115_200, .ibrd = 1, .fbrd = 0 },
        .{ .uartclk = 24_000_000, .baud = 230_400, .ibrd = 6, .fbrd = 33 },
        .{ .uartclk = 16_000_000, .baud = 57_600, .ibrd = 17, .fbrd = 23 },
        .{ .uartclk = 7_372_800, .baud = 115_200, .ibrd = 4, .fbrd = 0 },
        .{ .uartclk = 26_000_000, .baud = 115_200, .ibrd = 14, .fbrd = 7 },
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
