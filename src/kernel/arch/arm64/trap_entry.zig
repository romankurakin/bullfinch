//! ARM64 Trap Entry Assembly Generator.
//!
//! Generates entry/exit assembly from a single template with comptime configuration.
//! Offsets are derived from TrapFrame via @offsetOf so struct layout changes cause
//! compile errors rather than silent corruption.
//!
//! Uses STP/LDP for paired 16-byte stores/loads. The fast path saves only caller-saved
//! registers (x0-x18, x30) while full save includes callee-saved (x19-x28, x29).
//!
//! See ARM Architecture Reference Manual, D1.4 (Exceptions).

const std = @import("std");
const fmt = std.fmt;
const trap_frame = @import("trap_frame.zig");
const TrapFrame = trap_frame.TrapFrame;

/// Configuration for a trap entry point.
pub const EntryConfig = struct {
    /// Save all registers (288B) vs caller-saved only (176B).
    full_save: bool,
    /// Name of the Zig handler function to call.
    handler: []const u8,
    /// Pass frame pointer in x0 to handler.
    pass_frame: bool,
    /// Save user stack pointer from SP_EL0 (user traps only).
    /// When true, reads SP_EL0 instead of computing from current SP.
    save_sp_el0: bool = false,
    /// Check need_resched flag and call preemptFromTrap before eret.
    /// Use for interrupt handlers where preemption is safe.
    check_preempt: bool = false,
};

/// Frame sizes (16-byte aligned).
pub const FULL_FRAME_SIZE = @sizeOf(TrapFrame);
pub const FAST_FRAME_SIZE = 176;

// Offsets derived from TrapFrame layout.
const OFF_REGS = @offsetOf(TrapFrame, "regs");
const OFF_X30 = OFF_REGS + 30 * 8;
const OFF_SP = @offsetOf(TrapFrame, "sp_saved");
const OFF_ELR = @offsetOf(TrapFrame, "elr");
const OFF_SPSR = @offsetOf(TrapFrame, "spsr");
const OFF_ESR = @offsetOf(TrapFrame, "esr");
const OFF_FAR = @offsetOf(TrapFrame, "far");

// Fast frame offsets (caller-saved only, not TrapFrame-compatible).
const FAST_OFF_X18_X30 = 144; // After x0-x17 pairs
const FAST_OFF_ELR = 160; // After x18, x30

pub fn genEntryAsm(comptime cfg: EntryConfig) []const u8 {
    return genSaveAsm(cfg.full_save, cfg.save_sp_el0) ++
        (if (cfg.pass_frame) "mov x0, sp\n" else "") ++
        "bl " ++ cfg.handler ++ "\n" ++
        (if (cfg.check_preempt) genPreemptCheckAsm() else "") ++
        genRestoreAsm(cfg.full_save) ++
        \\eret
    ;
}

/// Generate preemption check: if need_resched is set, call preemptFromTrap.
/// Called after handler returns, before trap frame restore.
fn genPreemptCheckAsm() []const u8 {
    // Load need_resched directly (exported from scheduler).
    // Uses x0 as scratch (will be restored from trap frame anyway).
    return 
    \\adrp x0, need_resched
    \\ldrb w0, [x0, :lo12:need_resched]
    \\cbz w0, 1f
    \\bl preemptFromTrap
    \\1:
    \\
    ;
}

fn genSaveAsm(comptime full: bool, comptime save_sp_el0: bool) []const u8 {
    return if (full) genFullSaveAsm(save_sp_el0) else genCallerSaveAsm();
}

fn genRestoreAsm(comptime full: bool) []const u8 {
    return if (full) genFullRestoreAsm() else genCallerRestoreAsm();
}

/// Full save: all GPRs (x0-x30) + SP + system registers.
/// User traps read SP_EL0; kernel traps compute from current SP.
/// See ARM Architecture Reference Manual, D1.8.2 (SP_EL0).
fn genFullSaveAsm(comptime save_sp_el0: bool) []const u8 {
    // User traps read SP_EL0 (user's stack pointer).
    // Kernel traps compute original SP from current SP + frame size.
    const save_sp = if (save_sp_el0)
        \\mrs x0, sp_el0
        \\
    else
        fmt.comptimePrint(
            \\add x0, sp, #{d}
            \\
        , .{FULL_FRAME_SIZE});

    return fmt.comptimePrint(
        \\sub sp, sp, #{[frame]d}
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x19, [sp, #144]
        \\stp x20, x21, [sp, #160]
        \\stp x22, x23, [sp, #176]
        \\stp x24, x25, [sp, #192]
        \\stp x26, x27, [sp, #208]
        \\stp x28, x29, [sp, #224]
        \\
    , .{ .frame = FULL_FRAME_SIZE }) ++ save_sp ++ fmt.comptimePrint(
        \\stp x30, x0, [sp, #{[x30]d}]
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #{[elr]d}]
        \\mrs x0, esr_el1
        \\mrs x1, far_el1
        \\stp x0, x1, [sp, #{[esr]d}]
        \\
    , .{ .x30 = OFF_X30, .elr = OFF_ELR, .esr = OFF_ESR });
}

/// Caller-saved only: x0-x18, x30 + ELR/SPSR for eret.
fn genCallerSaveAsm() []const u8 {
    return fmt.comptimePrint(
        \\sub sp, sp, #{[frame]d}
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x30, [sp, #{[x18]d}]
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #{[elr]d}]
        \\
    , .{ .frame = FAST_FRAME_SIZE, .x18 = FAST_OFF_X18_X30, .elr = FAST_OFF_ELR });
}

/// Full restore: all GPRs + system registers, deallocate frame.
fn genFullRestoreAsm() []const u8 {
    return fmt.comptimePrint(
        \\ldp x0, x1, [sp, #{[elr]d}]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1
        \\ldp x2, x3, [sp, #16]
        \\ldp x4, x5, [sp, #32]
        \\ldp x6, x7, [sp, #48]
        \\ldp x8, x9, [sp, #64]
        \\ldp x10, x11, [sp, #80]
        \\ldp x12, x13, [sp, #96]
        \\ldp x14, x15, [sp, #112]
        \\ldp x16, x17, [sp, #128]
        \\ldp x18, x19, [sp, #144]
        \\ldp x20, x21, [sp, #160]
        \\ldp x22, x23, [sp, #176]
        \\ldp x24, x25, [sp, #192]
        \\ldp x26, x27, [sp, #208]
        \\ldp x28, x29, [sp, #224]
        \\ldr x30, [sp, #{[x30]d}]
        \\ldp x0, x1, [sp, #0]
        \\add sp, sp, #{[frame]d}
        \\
    , .{ .frame = FULL_FRAME_SIZE, .x30 = OFF_X30, .elr = OFF_ELR });
}

/// Caller-saved restore: x0-x18, x30 + system registers, deallocate frame.
fn genCallerRestoreAsm() []const u8 {
    return fmt.comptimePrint(
        \\ldp x0, x1, [sp, #{[elr]d}]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1
        \\ldp x2, x3, [sp, #16]
        \\ldp x4, x5, [sp, #32]
        \\ldp x6, x7, [sp, #48]
        \\ldp x8, x9, [sp, #64]
        \\ldp x10, x11, [sp, #80]
        \\ldp x12, x13, [sp, #96]
        \\ldp x14, x15, [sp, #112]
        \\ldp x16, x17, [sp, #128]
        \\ldp x18, x30, [sp, #{[x18]d}]
        \\ldp x0, x1, [sp, #0]
        \\add sp, sp, #{[frame]d}
        \\
    , .{ .frame = FAST_FRAME_SIZE, .x18 = FAST_OFF_X18_X30, .elr = FAST_OFF_ELR });
}

const mem = std.mem;

test "generates full-save entry asm with expected structure" {
    const asm_str = comptime genEntryAsm(.{
        .full_save = true,
        .handler = "handleTrap",
        .pass_frame = true,
    });

    const frame_alloc = comptime fmt.comptimePrint("sub sp, sp, #{d}", .{FULL_FRAME_SIZE});
    const frame_dealloc = comptime fmt.comptimePrint("add sp, sp, #{d}", .{FULL_FRAME_SIZE});

    try std.testing.expect(mem.indexOf(u8, asm_str, frame_alloc) != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, frame_dealloc) != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "bl handleTrap") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "mov x0, sp") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "eret") != null);
}

test "omits callee-saved registers in fast-path entry asm" {
    const asm_str = comptime genCallerSaveAsm();

    try std.testing.expect(mem.indexOf(u8, asm_str, "x0, x1") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "x18, x30") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "x19") == null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "x28") == null);
}

test "keeps save/restore register coverage consistent" {
    const full_stp = comptime mem.count(u8, genFullSaveAsm(false), "stp");
    const full_ldp = comptime mem.count(u8, genFullRestoreAsm(), "ldp");
    const full_ldr = comptime mem.count(u8, genFullRestoreAsm(), "ldr ");

    try std.testing.expectEqual(@as(usize, 18), full_stp);
    try std.testing.expectEqual(@as(usize, 16), full_ldp);
    try std.testing.expectEqual(@as(usize, 1), full_ldr); // x30 alone

    const fast_stp = comptime mem.count(u8, genCallerSaveAsm(), "stp");
    const fast_ldp = comptime mem.count(u8, genCallerRestoreAsm(), "ldp");

    try std.testing.expectEqual(fast_stp, fast_ldp);
}

// Compile-time verification
comptime {
    // Verify frame sizes are 16-byte aligned (AAPCS64 requirement)
    if (FULL_FRAME_SIZE & 0xF != 0)
        @compileError("FULL_FRAME_SIZE must be 16-byte aligned");
    if (FAST_FRAME_SIZE & 0xF != 0)
        @compileError("FAST_FRAME_SIZE must be 16-byte aligned");

    // Verify frame size matches TrapFrame struct
    if (FULL_FRAME_SIZE != TrapFrame.FRAME_SIZE)
        @compileError("FULL_FRAME_SIZE must match TrapFrame.FRAME_SIZE");

    // Verify assembly offsets match TrapFrame layout
    if (OFF_REGS != 0)
        @compileError("regs must be at offset 0");
    if (OFF_X30 != 240)
        @compileError("x30 offset mismatch - check regs array size");
    if (OFF_SP != 248)
        @compileError("sp_saved offset mismatch - assembly uses 248(sp)");
    if (OFF_ELR != 256)
        @compileError("elr offset mismatch - assembly uses 256(sp)");
    if (OFF_SPSR != 264)
        @compileError("spsr offset mismatch - assembly uses 264(sp)");
    if (OFF_ESR != 272)
        @compileError("esr offset mismatch - assembly uses 272(sp)");
    if (OFF_FAR != 280)
        @compileError("far offset mismatch - assembly uses 280(sp)");

    // Fast path offsets (caller-saved only)
    if (FAST_OFF_X18_X30 != 144)
        @compileError("FAST_OFF_X18_X30 offset mismatch");
    if (FAST_OFF_ELR != 160)
        @compileError("FAST_OFF_ELR offset mismatch");
}
