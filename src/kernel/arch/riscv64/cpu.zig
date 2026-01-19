//! RISC-V CPU Primitives.
//!
//! Low-level interrupt control, synchronization, and speculation barriers.
//! See RISC-V Privileged and Unprivileged ISA specifications for details.

const std = @import("std");

/// Disable supervisor interrupts. Returns true if interrupts were previously enabled.
pub inline fn disableInterrupts() bool {
    var sstatus: u64 = undefined;
    asm volatile ("csrr %[sstatus], sstatus"
        : [sstatus] "=r" (sstatus),
    );
    asm volatile ("csrci sstatus, 0x2");
    return (sstatus & 0x2) != 0;
}

/// Enable supervisor interrupts.
pub inline fn enableInterrupts() void {
    asm volatile ("csrsi sstatus, 0x2");
}

/// Wait for interrupt (low-power sleep until interrupt).
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}

/// Halt CPU forever (interrupts remain enabled).
pub inline fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

/// Spin until low 16 bits of value at `ptr` equals `expected`.
/// Uses Zihintpause hint for power-efficient polling.
pub fn spinWaitEq16(ptr: *const u32, expected: u16) void {
    while (@as(u16, @truncate(loadAcquire32(ptr))) != expected) pause();
}

/// Speculation barrier (FENCE). Use after bounds checks on untrusted indices.
pub inline fn speculationBarrier() void {
    asm volatile ("fence iorw, iorw");
}

inline fn pause() void {
    // PAUSE hint: reduces power in spin loops (NOP on older cores).
    asm volatile (".insn i 0x0F, 0, x0, x0, 0x10");
}

inline fn loadAcquire32(ptr: *const u32) u32 {
    return @as(*const std.atomic.Value(u32), @ptrCast(ptr)).load(.acquire);
}
