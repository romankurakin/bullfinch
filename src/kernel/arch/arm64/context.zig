//! ARM64 Context Switch.
//!
//! Saves registers needed for voluntary context switch. Separate from TrapFrame
//! which saves all registers during traps/interrupts.
//!
//! AAPCS64 callee-saved: x19-x28, x29 (fp), sp. We also save x30 (lr) because
//! it holds the return address for resuming execution after switchContext.
//! Total: 14 slots × 8 bytes = 112 bytes, padded to 128 for alignment.
//!
//! See AAPCS64, Table 2.

const std = @import("std");

/// Saved context. Layout must match switchContext assembly.
pub const Context = extern struct {
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    fp: u64 = 0, // x29
    lr: u64 = 0, // x30, return address
    sp: u64 = 0,
    irq_enabled: u64 = 1,
    _pad: [16]u8 = [_]u8{0} ** 16,

    pub const SIZE: usize = 128;

    comptime {
        if (@sizeOf(Context) != SIZE) @compileError("Context size mismatch");
        if (@sizeOf(Context) & 0xF != 0) @compileError("Context must be 16-byte aligned");
        if (@offsetOf(Context, "x19") != 0) @compileError("x19 offset mismatch");
        if (@offsetOf(Context, "x20") != 8) @compileError("x20 offset mismatch");
        if (@offsetOf(Context, "fp") != 80) @compileError("fp offset mismatch");
        if (@offsetOf(Context, "lr") != 88) @compileError("lr offset mismatch");
        if (@offsetOf(Context, "sp") != 96) @compileError("sp offset mismatch");
        if (@offsetOf(Context, "irq_enabled") != 104) @compileError("irq_enabled offset mismatch");
    }

    /// Initialize for new thread. fp=0 terminates backtraces.
    pub fn init(entry_pc: usize, stack_top: usize) Context {
        return .{ .lr = entry_pc, .sp = stack_top, .irq_enabled = 1 };
    }

    /// Store entry/arg in x19/x20 for threadTrampoline.
    pub fn setEntryData(ctx: *Context, entry: usize, arg: usize) void {
        ctx.x19 = entry;
        ctx.x20 = arg;
    }
};

/// Entry point for new threads. Reads entry/arg from x19/x20, jumps to threadStart.
pub fn threadTrampoline() callconv(.naked) noreturn {
    asm volatile (
        \\ mov x0, x19
        \\ mov x1, x20
        \\ b threadStart
    );
}

pub extern fn switchContext(old: *Context, new: *Context) void;

comptime {
    asm (
        \\ .text
        \\ .align 2
        \\ .global switchContext
        \\ .type switchContext, %function
        \\ switchContext:
        \\     stp x19, x20, [x0, #0]
        \\     stp x21, x22, [x0, #16]
        \\     stp x23, x24, [x0, #32]
        \\     stp x25, x26, [x0, #48]
        \\     stp x27, x28, [x0, #64]
        \\     stp x29, x30, [x0, #80]
        \\     mov x2, sp
        \\     str x2, [x0, #96]
        \\
        \\     ldp x19, x20, [x1, #0]
        \\     ldp x21, x22, [x1, #16]
        \\     ldp x23, x24, [x1, #32]
        \\     ldp x25, x26, [x1, #48]
        \\     ldp x27, x28, [x1, #64]
        \\     ldp x29, x30, [x1, #80]
        \\     ldr x2, [x1, #96]
        \\     mov sp, x2
        \\
        \\     // Restore IRQ state. PSTATE writes need no ISB.
        \\     ldr x2, [x1, #104]
        \\     cbz x2, 1f
        \\     msr daifclr, #3
        \\     b 2f
        \\ 1:
        \\     msr daifset, #3
        \\ 2:
        \\     ret
    );
}
