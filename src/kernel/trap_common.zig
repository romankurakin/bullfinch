//! Common trap handling utilities shared between architectures.

const builtin = @import("builtin");

// HAL stub in test mode (zig test doesn't resolve modules).
const hal = if (builtin.is_test)
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

/// Print a decimal number.
pub fn printDecimal(val: usize) void {
    if (val >= 10) {
        var buf: [2]u8 = undefined;
        buf[0] = @as(u8, @truncate('0' + (val / 10)));
        buf[1] = @as(u8, @truncate('0' + (val % 10)));
        hal.print(&buf);
    } else {
        var buf: [1]u8 = undefined;
        buf[0] = @as(u8, @truncate('0' + val));
        hal.print(&buf);
    }
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
    var i: usize = 0;
    while (i < regs.len) : (i += 4) {
        // Register 1
        if (i < names.len) {
            printRegName(names[i]);
            hal.print("=0x");
            printHex(regs[i]);
        }

        // Register 2
        if (i + 1 < regs.len and i + 1 < names.len) {
            hal.print(" ");
            printRegName(names[i + 1]);
            hal.print("=0x");
            printHex(regs[i + 1]);
        }

        // Register 3
        if (i + 2 < regs.len and i + 2 < names.len) {
            hal.print(" ");
            printRegName(names[i + 2]);
            hal.print("=0x");
            printHex(regs[i + 2]);
        }

        // Register 4
        if (i + 3 < regs.len and i + 3 < names.len) {
            hal.print(" ");
            printRegName(names[i + 3]);
            hal.print("=0x");
            printHex(regs[i + 3]);
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
