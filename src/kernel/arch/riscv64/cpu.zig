//! RISC-V CPU primitives for synchronization.
//!
//! RISC-V lacks ARM's exclusive monitor / WFE mechanism. Uses Zihintpause to
//! hint the CPU to reduce power in spin loops (backward-compatible NOP).
//!
//! See RISC-V Unprivileged ISA, "Zihintpause" Pause Hint extension.

const std = @import("std");

inline fn pause() void {
    // PAUSE hint (FENCE pred=W, succ=0). Reduces power in spin loops on
    // Zihintpause cores, executes as NOP on older cores. Raw encoding avoids
    // toolchain dependency while maintaining backward compatibility.
    asm volatile (".insn i 0x0F, 0, x0, x0, 0x10");
}

inline fn loadAcquire32(ptr: *const u32) u32 {
    return @as(*const std.atomic.Value(u32), @ptrCast(ptr)).load(.acquire);
}

inline fn storeRelease32(ptr: *u32, val: u32) void {
    @as(*std.atomic.Value(u32), @ptrCast(ptr)).store(val, .release);
}

/// Spin until 32-bit value at `ptr` equals `expected`.
pub fn spinWaitEq(ptr: *const u32, expected: u32) void {
    while (loadAcquire32(ptr) != expected) pause();
}

/// Store with release semantics.
pub const storeRelease = storeRelease32;
