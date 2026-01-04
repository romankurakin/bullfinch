//! Memory-mapped I/O helpers for ARM64.

pub inline fn read32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

pub inline fn write32(addr: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}

pub inline fn write8(addr: usize, val: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = val;
}
