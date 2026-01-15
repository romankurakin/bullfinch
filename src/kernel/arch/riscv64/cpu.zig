//! RISC-V CPU primitives for synchronization and speculation control.
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

/// Speculation barrier for Spectre-v1 (bounds check bypass) mitigation.
///
/// CPUs may speculatively execute past bounds checks before the check completes.
/// If an attacker controls an array index (e.g., syscall number), the CPU might
/// speculatively access out-of-bounds memory, leaking data via cache timing.
///
/// RISC-V has no dedicated speculation barrier. FENCE acts as a conservative
/// barrier but effectiveness is implementation-dependent. Some cores may not
/// speculate past branches at all. Use after bounds checks on untrusted indices.
///
/// See RISC-V Unprivileged ISA, Chapter 2 (FENCE).
pub inline fn speculationBarrier() void {
    asm volatile ("fence iorw, iorw");
}
