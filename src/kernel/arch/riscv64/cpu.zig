//! RISC-V CPU primitives for synchronization.
//!
//! RISC-V lacks ARM's exclusive monitor / WFE mechanism. Uses Zihintpause to
//! hint the CPU to reduce power in spin loops (backward-compatible NOP).
//!
//! See RISC-V Unprivileged ISA, Chapter 9 (Zihintpause).

const std = @import("std");

inline fn pause() void {
    // PAUSE hint (FENCE pred=W, succ=0). Reduces power in spin loops on
    // Zihintpause cores, executes as NOP on older cores.
    asm volatile (".insn i 0x0F, 0, x0, x0, 0x10");
}

inline fn loadAcquire32(ptr: *const u32) u32 {
    return @as(*const std.atomic.Value(u32), @ptrCast(ptr)).load(.acquire);
}

/// Spin until low 16 bits of value at `ptr` equals `expected`.
pub fn spinWaitEq16(ptr: *const u32, expected: u16) void {
    while (@as(u16, @truncate(loadAcquire32(ptr))) != expected) pause();
}
