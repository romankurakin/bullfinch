//! RISC-V Context Switch.
//!
//! Callee-saved registers for voluntary context switch. This is separate from
//! the TrapFrame which saves all registers during traps/interrupts.
//!
//! psABI callee-saved: s0-s11 (x8-x9, x18-x27), ra (x1), sp (x2).
//! Total: 14 registers × 8 bytes = 112 bytes.
//! Padded to 128 bytes for 16-byte alignment and cache line efficiency.
//!
//! See RISC-V psABI, Chapter 1 (Register Convention).

const std = @import("std");

/// Layout must match switchContext assembly.
pub const Context = extern struct {
    s0: u64 = 0, // x8, fp
    s1: u64 = 0, // x9
    s2: u64 = 0, // x18
    s3: u64 = 0, // x19
    s4: u64 = 0, // x20
    s5: u64 = 0, // x21
    s6: u64 = 0, // x22
    s7: u64 = 0, // x23
    s8: u64 = 0, // x24
    s9: u64 = 0, // x25
    s10: u64 = 0, // x26
    s11: u64 = 0, // x27
    ra: u64 = 0, // x1, return address
    sp: u64 = 0, // x2
    irq_enabled: u64 = 1,
    _pad: [8]u8 = [_]u8{0} ** 8,

    pub const SIZE: usize = 128;

    comptime {
        if (@sizeOf(Context) != SIZE) @compileError("Context size mismatch");
        if (@sizeOf(Context) & 0xF != 0) @compileError("Context must be 16-byte aligned");
        if (@offsetOf(Context, "s0") != 0) @compileError("s0 offset mismatch");
        if (@offsetOf(Context, "s1") != 8) @compileError("s1 offset mismatch");
        if (@offsetOf(Context, "s11") != 88) @compileError("s11 offset mismatch");
        if (@offsetOf(Context, "ra") != 96) @compileError("ra offset mismatch");
        if (@offsetOf(Context, "sp") != 104) @compileError("sp offset mismatch");
        if (@offsetOf(Context, "irq_enabled") != 112) @compileError("irq_enabled offset mismatch");
    }

    /// s0 (fp)=0 terminates backtraces.
    pub fn init(entry_pc: usize, stack_top: usize) Context {
        return .{ .ra = entry_pc, .sp = stack_top, .irq_enabled = 1 };
    }

    /// Store entry point and argument for threadTrampoline to retrieve.
    /// Uses s2/s3 (s0 is fp, s1 may be used by compiler).
    pub fn setEntryData(ctx: *Context, entry: usize, arg: usize) void {
        ctx.s2 = entry;
        ctx.s3 = arg;
    }
};

/// First code a new thread runs. Reads entry/arg from s2/s3 then jumps to threadStart.
pub fn threadTrampoline() callconv(.naked) noreturn {
    asm volatile (
        \\ mv a0, s2
        \\ mv a1, s3
        \\ j threadStart
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
        \\     sd s0, 0(a0)
        \\     sd s1, 8(a0)
        \\     sd s2, 16(a0)
        \\     sd s3, 24(a0)
        \\     sd s4, 32(a0)
        \\     sd s5, 40(a0)
        \\     sd s6, 48(a0)
        \\     sd s7, 56(a0)
        \\     sd s8, 64(a0)
        \\     sd s9, 72(a0)
        \\     sd s10, 80(a0)
        \\     sd s11, 88(a0)
        \\     sd ra, 96(a0)
        \\     sd sp, 104(a0)
        \\
        \\     ld s0, 0(a1)
        \\     ld s1, 8(a1)
        \\     ld s2, 16(a1)
        \\     ld s3, 24(a1)
        \\     ld s4, 32(a1)
        \\     ld s5, 40(a1)
        \\     ld s6, 48(a1)
        \\     ld s7, 56(a1)
        \\     ld s8, 64(a1)
        \\     ld s9, 72(a1)
        \\     ld s10, 80(a1)
        \\     ld s11, 88(a1)
        \\     ld ra, 96(a1)
        \\     ld sp, 104(a1)
        \\
        \\     ld t0, 112(a1)
        \\     beqz t0, 1f
        \\     csrsi sstatus, 0x2
        \\     j 2f
        \\ 1:
        \\     csrci sstatus, 0x2
        \\ 2:
        \\     ret
    );
}
