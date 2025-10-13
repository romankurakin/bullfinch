//! PL011 UART driver for ARM64 platforms - TX only version.
//! The PL011 is ARM's standard UART peripheral used in many ARM-based SoCs.
//! Provides direct MMIO access to UART hardware for output. Callers supply base address.
//! Peripheral powers up disabled - must configure baud divisors and enable TX.
//!
//! REGISTER OFFSETS - These are byte offsets from the UART base address
//! The PL011 has its registers laid out in a specific memory map
const UART_DR_OFFSET = 0x00; // Data Register - where write bytes to transmit
const UART_FR_OFFSET = 0x18; // Flag Register - status flags (FIFO full, busy, etc)
const UART_IBRD_OFFSET = 0x24; // Integer Baud Rate Divisor - controls baud rate
const UART_FBRD_OFFSET = 0x28; // Fractional Baud Rate Divisor - fine-tunes baud rate
const UART_LCRH_OFFSET = 0x2C; // Line Control Register - configure data format
const UART_CR_OFFSET = 0x30; // Control Register - enable/disable UART and features
const UART_ICR_OFFSET = 0x44; // Interrupt Clear Register

// FLAG REGISTER BITS - These are bit positions within the FR register
const UART_FR_TXFF = 1 << 5; // Transmit FIFO Full flag (1 = full, can't send)
const UART_FR_BUSY = 1 << 3; // UART Busy flag (1 = transmitting)

// CONTROL REGISTER BITS - These control UART operation
const UART_CR_UARTEN = 1 << 0; // UART Enable bit
const UART_CR_TXE = 1 << 8; // Transmit Enable bit

// LINE CONTROL REGISTER BITS - These configure data format
const UART_LCRH_FEN = 1 << 4; // FIFO Enable (use 16-byte buffers)
const UART_LCRH_WLEN_8 = 0b11 << 5; // Word length = 8 bits (shifted to bits 6:5)

pub const InitConfig = struct {
    uartclk_hz: u32 = 24_000_000, // Input clock frequency to UART peripheral
    baud: u32 = 115_200, // Desired baud rate (bits per second)
};

pub const State = struct {
    initialized: bool = false,
};

// MMIO REGISTER ACCESS FUNCTIONS
// ARM memory-mapped I/O requires volatile to prevent compiler optimizations
// The compiler must not cache these reads/writes or reorder them
inline fn reg32(base: usize, comptime offset: usize) *volatile u32 {
    return @as(*volatile u32, @ptrFromInt(base + offset));
}

inline fn reg8(base: usize, comptime offset: usize) *volatile u8 {
    return @as(*volatile u8, @ptrFromInt(base + offset));
}

/// Wait until there is space in the TX FIFO (transmit buffer).
inline fn waitTxFifo(base: usize) void {
    while ((reg32(base, UART_FR_OFFSET).* & UART_FR_TXFF) != 0) {}
}

/// Write a byte of data to the UART's Data Register for transmission.
inline fn writeData(base: usize, byte: u8) void {
    reg8(base, UART_DR_OFFSET).* = byte;
}

// Compute baud rate divisors per PL011 spec. Uses u64 to prevent overflow.
// The PL011 uses a 16x oversampling clock, so the baud divisor is:
// divisor = uartclk_hz / (16 * baud)
// This is split into integer and fractional parts (6 bits of fraction)
pub fn computeDivisors(uartclk_hz: u32, baud: u32) struct { ibrd: u32, fbrd: u32 } {
    // Avoid division by zero
    if (baud == 0) @panic("baud must be non-zero");

    const denom = @as(u64, 16) * @as(u64, baud); // 16 * baud
    const clk = @as(u64, uartclk_hz); // Clock frequency
    const ibrd = clk / denom; // Integer part of baud rate divisor
    const remainder = clk - denom * ibrd; // Remainder for fractional part
    const fbrd = (remainder * 64 + denom / 2) / denom; // Rounding for fractional part

    // Validate divisor ranges per PL011 specification
    // IBRD must be 1-65535, FBRD must be 0-63
    if (ibrd < 1 or ibrd > 65535) @panic("IBRD out of valid range 1-65535");
    if (fbrd > 63) @panic("FBRD out of valid range 0-63");

    return .{ .ibrd = @intCast(ibrd), .fbrd = @intCast(fbrd) };
}

// Helper to program baud rate into hardware registers
fn setBaud(base: usize, uartclk_hz: u32, baud: u32) void {
    const divs = computeDivisors(uartclk_hz, baud);
    reg32(base, UART_IBRD_OFFSET).* = divs.ibrd;
    reg32(base, UART_FBRD_OFFSET).* = divs.fbrd;
}

// Must be called before any UART operations
pub fn init(base: usize, state: *State, config: InitConfig) void {
    // Wait for any ongoing transmissions to complete
    // This prevents data loss if UART was previously active
    while ((reg32(base, UART_FR_OFFSET).* & UART_FR_BUSY) != 0) {}

    // Disable UART completely for configuration
    // Hardware requires UART to be disabled when changing settings
    reg32(base, UART_CR_OFFSET).* = 0;

    // Clear any pending interrupts from previous use
    // Write all 1s to clear all interrupt flags
    reg32(base, UART_ICR_OFFSET).* = 0x7FF;

    // Set the baud rate divisors
    setBaud(base, config.uartclk_hz, config.baud);

    // Configure line control (data format)
    // 8 bits, no parity, 1 stop bit, FIFOs enabled
    // This is a common configuration for serial communication
    reg32(base, UART_LCRH_OFFSET).* = UART_LCRH_WLEN_8 | UART_LCRH_FEN;

    // Enable UART with TX only
    const cr: u32 = UART_CR_UARTEN | UART_CR_TXE;
    reg32(base, UART_CR_OFFSET).* = cr;

    // Data Synchronization Barrier - ensure UART enable write completes
    // ARM has weakly-ordered memory, so this guarantees the enable
    // write has reached the hardware before we continue
    asm volatile ("dsb ish");

    state.initialized = true;
}

// Convenience function with default 115200 baud @ 24MHz clock
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
        // Wait for space in TX FIFO
        // The FIFO can hold 16 bytes, but we check before each byte
        waitTxFifo(base);

        if (byte == '\n') {
            // Some terminals expect CR+LF for newlines
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
