//! Common trap handling utilities shared between architectures.

const builtin = @import("builtin");

/// HAL stub in test mode (zig test doesn't resolve modules).
/// Exported so architecture-specific trap handlers can reuse it.
pub const hal = if (builtin.is_test)
    struct {
        pub fn print(_: []const u8) void {}
    }
else
    @import("board").hal;

/// Print a 64-bit value as hex.
pub fn printHex(val: u64) void {
    const hex_chars = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @truncate(v & 0xF))];
        v >>= 4;
    }
    hal.print(&buf);
}

/// Print a decimal number (handles any usize value).
pub fn printDecimal(val: usize) void {
    var buf: [20]u8 = undefined; // Max 20 digits for 64-bit
    var v = val;
    var i: usize = buf.len;

    if (v == 0) {
        hal.print("0");
        return;
    }

    while (v > 0) : (i -= 1) {
        buf[i - 1] = @as(u8, @truncate('0' + (v % 10)));
        v /= 10;
    }

    hal.print(buf[i..]);
}

/// Print a register name with padding to 7 characters.
fn printRegName(name: []const u8) void {
    hal.print(name);
    // Pad to 7 characters for consistent alignment
    var padding = 7 -% name.len;
    while (padding > 0) : (padding -= 1) {
        hal.print(" ");
    }
}

/// Dump general purpose registers in a 4-column layout.
pub fn dumpRegisters(regs: []const u64, names: []const []const u8) void {
    const cols = 4;
    var row: usize = 0;
    while (row * cols < regs.len) : (row += 1) {
        for (0..cols) |col| {
            const idx = row * cols + col;
            if (idx >= regs.len or idx >= names.len) break;

            if (col > 0) hal.print(" ");
            printRegName(names[idx]);
            hal.print("=0x");
            printHex(regs[idx]);
        }
        hal.print("\n");
    }
}

/// Print trap header line: "Trap: <name>\n"
pub fn printTrapHeader(trap_name: []const u8) void {
    hal.print("Trap: ");
    hal.print(trap_name);
    hal.print("\n");
}

/// Print a key register with 7-char padded name: "<name>=0x<hex>"
pub fn printKeyRegister(name: []const u8, value: u64) void {
    printRegName(name);
    hal.print("=0x");
    printHex(value);
}
