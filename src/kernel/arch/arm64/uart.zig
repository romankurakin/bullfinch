//! PL011 UART driver for ARM64 - TX only, direct MMIO.
//! ARM's standard UART peripheral. Powers up disabled, requires baud rate config + enable.

// PL011 register offsets (byte offsets from base address)
const DR = 0x00; // Data Register
const FR = 0x18; // Flag Register
const IBRD = 0x24; // Integer Baud Rate Divisor
const FBRD = 0x28; // Fractional Baud Rate Divisor
const LCRH = 0x2C; // Line Control Register
const CR = 0x30; // Control Register
const ICR = 0x44; // Interrupt Clear Register

const FR_TXFF: u32 = 1 << 5; // TX FIFO Full
const FR_BUSY: u32 = 1 << 3; // UART Busy

const CR_UARTEN: u32 = 1 << 0; // UART Enable
const CR_TXE: u32 = 1 << 8; // TX Enable
const CR_ENABLED: u32 = CR_UARTEN | CR_TXE;

const LCRH_FEN: u32 = 1 << 4; // FIFO Enable
const LCRH_WLEN_8: u32 = 0b11 << 5; // 8-bit word length

pub const InitConfig = struct {
    uartclk_hz: u32 = 24_000_000,
    baud: u32 = 115_200,
};

// MMIO access (volatile required for memory-mapped I/O)
inline fn reg32(base: usize, offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

inline fn waitTxReady(base: usize) void {
    while ((reg32(base, FR).* & FR_TXFF) != 0) {}
}

inline fn writeByte(base: usize, byte: u8) void {
    reg32(base, DR).* = byte;
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

/// Initialize UART (disable, configure baud rate + line control, enable).
pub fn init(base: usize, config: InitConfig) void {
    while ((reg32(base, FR).* & FR_BUSY) != 0) {} // Wait for TX to complete
    reg32(base, CR).* = 0; // Disable UART for config
    reg32(base, ICR).* = 0x7FF; // Clear interrupts

    const divs = computeDivisors(config.uartclk_hz, config.baud);
    reg32(base, IBRD).* = divs.ibrd;
    reg32(base, FBRD).* = divs.fbrd;
    reg32(base, LCRH).* = LCRH_WLEN_8 | LCRH_FEN; // 8N1, FIFOs enabled

    reg32(base, CR).* = CR_ENABLED;
    asm volatile ("dsb ish"); // Ensure write reaches hardware
}

pub fn initDefault(base: usize) void {
    init(base, .{});
}

/// Print string to UART.
pub fn print(base: usize, s: []const u8) void {
    if ((reg32(base, CR).* & CR_ENABLED) != CR_ENABLED) {
        @panic("UART not enabled");
    }

    for (s) |byte| {
        waitTxReady(base);
        if (byte == '\n') {
            writeByte(base, '\r');
            waitTxReady(base);
        }
        writeByte(base, byte);
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
