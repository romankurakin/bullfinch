//! Kernel Console Output.
//!
//! Early boot console for kernel messages. Architecture-specific UART backends
//! (PL011 for ARM, SBI for RISC-V) are selected at compile time.
//!
//! This is a temporary kernel-mode driver. Eventually UART access moves to
//! userspace. The kernel will just provide MMIO VMOs and IRQ capabilities.

const builtin = @import("builtin");
const sync = @import("../sync/sync.zig");

const uart = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/uart.zig"),
    .riscv64 => @import("../arch/riscv64/uart.zig"),
    else => @compileError("Unsupported architecture"),
};

var lock: sync.SpinLock = .{};

/// Initialize console output.
pub fn init() void {
    uart.init();
}

/// Post-MMU transition: switch to virtual addresses if needed.
pub fn postMmuInit() void {
    uart.postMmuInit();
}

/// Print string to console with interrupt-safe locking.
pub fn print(s: []const u8) void {
    const held = lock.guard();
    defer held.release();
    uart.print(s);
}

/// Print directly to UART without locking.
///
/// Use only in panic paths and trap handlers. If a panic occurs while the
/// console lock is held, calling print() would deadlock waiting for a lock
/// that will never be released. Output may interleave on SMP, but garbled
/// panic messages are better than no messages.
pub fn printUnsafe(s: []const u8) void {
    uart.print(s);
}

/// Print a u64 value in hexadecimal.
pub fn printHex(value: u64) void {
    const hex_chars = "0123456789abcdef";
    var buf: [18]u8 = undefined; // "0x" + 16 hex digits
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 17;
    var v = value;
    while (i >= 2) : (i -= 1) {
        buf[i] = hex_chars[@intCast(v & 0xF)];
        v >>= 4;
    }

    const held = lock.guard();
    defer held.release();
    uart.print(&buf);
}

/// Print a decimal number.
pub fn printDec(value: u64) void {
    var buf: [20]u8 = undefined; // Max u64 is 20 digits
    var i: usize = 20;
    var v = value;

    if (v == 0) {
        const held = lock.guard();
        defer held.release();
        uart.print("0");
        return;
    }

    while (v > 0) : (i -= 1) {
        buf[i - 1] = @intCast('0' + (v % 10));
        v /= 10;
    }

    const held = lock.guard();
    defer held.release();
    uart.print(buf[i..20]);
}
