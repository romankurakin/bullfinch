//! RISC-V Trap Entry Assembly Generator.
//!
//! Generates entry/exit assembly from a single template with comptime configuration.
//! Offsets are derived from TrapFrame via @offsetOf so struct layout changes cause
//! compile errors rather than silent corruption.
//!
//! The fast path saves only caller-saved registers (ra, t0-t6, a0-a7) while full
//! save includes callee-saved (s0-s11). User traps swap SP with sscratch to enter
//! on kernel stack before saving any registers.
//!
//! See RISC-V Privileged Specification, Chapter 12 (Supervisor-Level ISA).

const std = @import("std");
const fmt = std.fmt;
const trap_frame = @import("trap_frame.zig");
const TrapFrame = trap_frame.TrapFrame;

/// Configuration for a trap entry point.
pub const EntryConfig = struct {
    /// Save all registers (288B) vs caller-saved only (144B).
    full_save: bool,
    /// Name of the Zig handler function to call.
    handler: []const u8,
    /// Pass frame pointer in a0 to handler.
    pass_frame: bool,
    /// Swap SP with sscratch to enter on kernel stack (user traps only).
    /// See RISC-V Privileged Specification, 4.1.4 (Supervisor Scratch Register).
    use_sscratch: bool = false,
    /// Check need_resched flag and call preemptFromTrap before sret.
    /// Use for interrupt handlers where preemption is safe.
    check_preempt: bool = false,
};

/// Frame sizes (16-byte aligned).
pub const FULL_FRAME_SIZE = @sizeOf(TrapFrame);
pub const FAST_FRAME_SIZE = 144;

// Offsets derived from TrapFrame layout.
const OFF_REGS = @offsetOf(TrapFrame, "regs");
const OFF_X31 = OFF_REGS + 30 * 8;
const OFF_SP = @offsetOf(TrapFrame, "sp_saved");
const OFF_SEPC = @offsetOf(TrapFrame, "sepc");
const OFF_SSTATUS = @offsetOf(TrapFrame, "sstatus");
const OFF_SCAUSE = @offsetOf(TrapFrame, "scause");
const OFF_STVAL = @offsetOf(TrapFrame, "stval");

// Fast frame offsets (caller-saved only, not TrapFrame-compatible).
const FAST_OFF_SEPC = 128;
const FAST_OFF_SSTATUS = 136;

pub fn genEntryAsm(comptime cfg: EntryConfig) []const u8 {
    // For user traps, swap SP with sscratch to get kernel stack.
    // sscratch holds kernel SP; after swap, SP=kernel, sscratch=user.
    return (if (cfg.use_sscratch) "csrrw sp, sscratch, sp\n" else "") ++
        genSaveAsm(cfg.full_save, cfg.use_sscratch) ++
        (if (cfg.pass_frame) "mv a0, sp\n" else "") ++
        "call " ++ cfg.handler ++ "\n" ++
        (if (cfg.check_preempt) genPreemptCheckAsm() else "") ++
        genRestoreAsm(cfg.full_save) ++
        // Swap back: SP=user, sscratch=kernel (restored for next trap).
        (if (cfg.use_sscratch) "csrrw sp, sscratch, sp\n" else "") ++
        \\sret
    ;
}

/// Generate preemption check: if need_resched is set, call preemptFromTrap.
/// Called after handler returns, before trap frame restore.
fn genPreemptCheckAsm() []const u8 {
    // Load need_resched directly (exported from scheduler).
    // Uses t0 as scratch (will be restored from trap frame anyway).
    return
    \\la t0, need_resched
    \\lb t0, (t0)
    \\beqz t0, 1f
    \\call preemptFromTrap
    \\1:
    \\
    ;
}

fn genSaveAsm(comptime full: bool, comptime use_sscratch: bool) []const u8 {
    return if (full) genFullSaveAsm(use_sscratch) else genCallerSaveAsm();
}

fn genRestoreAsm(comptime full: bool) []const u8 {
    return if (full) genFullRestoreAsm() else genCallerRestoreAsm();
}

/// Full save: all GPRs (x1-x31) + original SP + trap CSRs.
/// User traps read SP from sscratch; kernel traps compute from current SP.
fn genFullSaveAsm(comptime use_sscratch: bool) []const u8 {
    // For user traps, x2 slot gets user SP from sscratch (after entry swap).
    // For kernel traps, x2 slot gets current SP value.
    const save_x2 = if (use_sscratch)
        \\csrr t0, sscratch
        \\sd t0, 8(sp)
        \\
    else
        \\sd x2, 8(sp)
        \\
    ;

    // sp_saved: user traps read from sscratch, kernel traps compute.
    const save_sp = if (use_sscratch)
        fmt.comptimePrint(
            \\csrr t0, sscratch
            \\sd t0, {[sp_off]d}(sp)
            \\
        , .{ .sp_off = OFF_SP })
    else
        fmt.comptimePrint(
            \\addi t0, sp, {[frame]d}
            \\sd t0, {[sp_off]d}(sp)
            \\
        , .{ .frame = FULL_FRAME_SIZE, .sp_off = OFF_SP });

    return fmt.comptimePrint(
        \\addi sp, sp, -{[frame]d}
        \\sd x1, 0(sp)
        \\
    , .{ .frame = FULL_FRAME_SIZE }) ++ save_x2 ++
        \\sd x3, 16(sp)
        \\sd x4, 24(sp)
        \\sd x5, 32(sp)
        \\sd x6, 40(sp)
        \\sd x7, 48(sp)
        \\sd x8, 56(sp)
        \\sd x9, 64(sp)
        \\sd x10, 72(sp)
        \\sd x11, 80(sp)
        \\sd x12, 88(sp)
        \\sd x13, 96(sp)
        \\sd x14, 104(sp)
        \\sd x15, 112(sp)
        \\sd x16, 120(sp)
        \\sd x17, 128(sp)
        \\sd x18, 136(sp)
        \\sd x19, 144(sp)
        \\sd x20, 152(sp)
        \\sd x21, 160(sp)
        \\sd x22, 168(sp)
        \\sd x23, 176(sp)
        \\sd x24, 184(sp)
        \\sd x25, 192(sp)
        \\sd x26, 200(sp)
        \\sd x27, 208(sp)
        \\sd x28, 216(sp)
        \\sd x29, 224(sp)
        \\sd x30, 232(sp)
        \\
    ++ fmt.comptimePrint(
        \\sd x31, {[x31]d}(sp)
        \\
    , .{ .x31 = OFF_X31 }) ++ save_sp ++ fmt.comptimePrint(
        \\csrr t0, sepc
        \\sd t0, {[sepc]d}(sp)
        \\csrr t0, sstatus
        \\sd t0, {[sstatus]d}(sp)
        \\csrr t0, scause
        \\sd t0, {[scause]d}(sp)
        \\csrr t0, stval
        \\sd t0, {[stval]d}(sp)
        \\
    , .{
        .sepc = OFF_SEPC,
        .sstatus = OFF_SSTATUS,
        .scause = OFF_SCAUSE,
        .stval = OFF_STVAL,
    });
}

/// Caller-saved only: ra, t0-t6, a0-a7 + sepc/sstatus for sret.
fn genCallerSaveAsm() []const u8 {
    return fmt.comptimePrint(
        \\addi sp, sp, -{[frame]d}
        \\sd ra, 0(sp)
        \\sd t0, 8(sp)
        \\sd t1, 16(sp)
        \\sd t2, 24(sp)
        \\sd a0, 32(sp)
        \\sd a1, 40(sp)
        \\sd a2, 48(sp)
        \\sd a3, 56(sp)
        \\sd a4, 64(sp)
        \\sd a5, 72(sp)
        \\sd a6, 80(sp)
        \\sd a7, 88(sp)
        \\sd t3, 96(sp)
        \\sd t4, 104(sp)
        \\sd t5, 112(sp)
        \\sd t6, 120(sp)
        \\csrr t0, sepc
        \\sd t0, {[sepc]d}(sp)
        \\csrr t0, sstatus
        \\sd t0, {[sstatus]d}(sp)
        \\
    , .{ .frame = FAST_FRAME_SIZE, .sepc = FAST_OFF_SEPC, .sstatus = FAST_OFF_SSTATUS });
}

/// Full restore: all GPRs + CSRs, deallocate frame.
fn genFullRestoreAsm() []const u8 {
    return fmt.comptimePrint(
        \\ld t0, {[sepc]d}(sp)
        \\csrw sepc, t0
        \\ld t0, {[sstatus]d}(sp)
        \\csrw sstatus, t0
        \\ld x1, 0(sp)
        \\ld x3, 16(sp)
        \\ld x4, 24(sp)
        \\ld x6, 40(sp)
        \\ld x7, 48(sp)
        \\ld x8, 56(sp)
        \\ld x9, 64(sp)
        \\ld x10, 72(sp)
        \\ld x11, 80(sp)
        \\ld x12, 88(sp)
        \\ld x13, 96(sp)
        \\ld x14, 104(sp)
        \\ld x15, 112(sp)
        \\ld x16, 120(sp)
        \\ld x17, 128(sp)
        \\ld x18, 136(sp)
        \\ld x19, 144(sp)
        \\ld x20, 152(sp)
        \\ld x21, 160(sp)
        \\ld x22, 168(sp)
        \\ld x23, 176(sp)
        \\ld x24, 184(sp)
        \\ld x25, 192(sp)
        \\ld x26, 200(sp)
        \\ld x27, 208(sp)
        \\ld x28, 216(sp)
        \\ld x29, 224(sp)
        \\ld x30, 232(sp)
        \\ld x31, {[x31]d}(sp)
        \\ld x5, 32(sp)
        \\addi sp, sp, {[frame]d}
        \\
    , .{
        .frame = FULL_FRAME_SIZE,
        .x31 = OFF_X31,
        .sepc = OFF_SEPC,
        .sstatus = OFF_SSTATUS,
    });
}

/// Caller-saved restore: ra, t0-t6, a0-a7 + CSRs, deallocate frame.
fn genCallerRestoreAsm() []const u8 {
    return fmt.comptimePrint(
        \\ld t0, {[sepc]d}(sp)
        \\csrw sepc, t0
        \\ld t0, {[sstatus]d}(sp)
        \\csrw sstatus, t0
        \\ld t3, 96(sp)
        \\ld t4, 104(sp)
        \\ld t5, 112(sp)
        \\ld t6, 120(sp)
        \\ld a0, 32(sp)
        \\ld a1, 40(sp)
        \\ld a2, 48(sp)
        \\ld a3, 56(sp)
        \\ld a4, 64(sp)
        \\ld a5, 72(sp)
        \\ld a6, 80(sp)
        \\ld a7, 88(sp)
        \\ld t0, 8(sp)
        \\ld t1, 16(sp)
        \\ld t2, 24(sp)
        \\ld ra, 0(sp)
        \\addi sp, sp, {[frame]d}
        \\
    , .{ .frame = FAST_FRAME_SIZE, .sepc = FAST_OFF_SEPC, .sstatus = FAST_OFF_SSTATUS });
}

const mem = std.mem;

test "generates full-save entry asm with expected structure" {
    const asm_str = comptime genEntryAsm(.{
        .full_save = true,
        .handler = "handleTrap",
        .pass_frame = true,
    });

    const frame_alloc = comptime fmt.comptimePrint("addi sp, sp, -{d}", .{FULL_FRAME_SIZE});
    const frame_dealloc = comptime fmt.comptimePrint("addi sp, sp, {d}", .{FULL_FRAME_SIZE});

    try std.testing.expect(mem.indexOf(u8, asm_str, frame_alloc) != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, frame_dealloc) != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "call handleTrap") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "mv a0, sp") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "sret") != null);
}

test "omits callee-saved registers in fast-path entry asm" {
    const asm_str = comptime genCallerSaveAsm();

    try std.testing.expect(mem.indexOf(u8, asm_str, "sd ra") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "sd t0") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "sd a0") != null);
    // s0-s11 are callee-saved, must not appear
    try std.testing.expect(mem.indexOf(u8, asm_str, "sd s0") == null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "sd s11") == null);
}

test "keeps save/restore instruction counts matching" {
    const full_sd = comptime mem.count(u8, genFullSaveAsm(false), "\nsd ");
    const full_ld = comptime mem.count(u8, genFullRestoreAsm(), "\nld ");
    const fast_sd = comptime mem.count(u8, genCallerSaveAsm(), "\nsd ");
    const fast_ld = comptime mem.count(u8, genCallerRestoreAsm(), "\nld ");

    try std.testing.expectEqual(full_sd, full_ld);
    try std.testing.expectEqual(fast_sd, fast_ld);
}

// Compile-time verification
comptime {
    // Verify frame sizes are 16-byte aligned (RISC-V ABI requirement)
    if (FULL_FRAME_SIZE & 0xF != 0)
        @compileError("FULL_FRAME_SIZE must be 16-byte aligned");
    if (FAST_FRAME_SIZE & 0xF != 0)
        @compileError("FAST_FRAME_SIZE must be 16-byte aligned");

    // Verify frame size matches TrapFrame struct
    if (FULL_FRAME_SIZE != TrapFrame.FRAME_SIZE)
        @compileError("FULL_FRAME_SIZE must match TrapFrame.FRAME_SIZE");

    // Verify assembly offsets match TrapFrame layout
    // These catch if struct fields are reordered or resized
    if (OFF_REGS != 0)
        @compileError("regs must be at offset 0");
    if (OFF_X31 != 240)
        @compileError("x31 offset mismatch - check regs array size");
    if (OFF_SP != 248)
        @compileError("sp_saved offset mismatch - assembly uses 248(sp)");
    if (OFF_SEPC != 256)
        @compileError("sepc offset mismatch - assembly uses 256(sp)");
    if (OFF_SSTATUS != 264)
        @compileError("sstatus offset mismatch - assembly uses 264(sp)");
    if (OFF_SCAUSE != 272)
        @compileError("scause offset mismatch - assembly uses 272(sp)");
    if (OFF_STVAL != 280)
        @compileError("stval offset mismatch - assembly uses 280(sp)");

    // Fast path offsets (caller-saved only)
    if (FAST_OFF_SEPC != 128)
        @compileError("FAST_OFF_SEPC offset mismatch");
    if (FAST_OFF_SSTATUS != 136)
        @compileError("FAST_OFF_SSTATUS offset mismatch");
}
