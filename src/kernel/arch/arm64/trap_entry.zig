//! ARM64 trap entry assembly generator.
//!
//! Generates entry/exit assembly from one template. Offsets come from TrapFrame
//! via @offsetOf so layout changes fail at comptime.
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
    return genSaveAsm(cfg.full_save) ++
        (if (cfg.pass_frame) "mov x0, sp\n" else "") ++
        "bl " ++ cfg.handler ++ "\n" ++
        genRestoreAsm(cfg.full_save) ++
        \\eret
    ;
}

fn genSaveAsm(comptime full: bool) []const u8 {
    return if (full) genFullSaveAsm() else genCallerSaveAsm();
}

fn genRestoreAsm(comptime full: bool) []const u8 {
    return if (full) genFullRestoreAsm() else genCallerRestoreAsm();
}

/// Full save: all GPRs (x0-x30) + SP + system registers.
fn genFullSaveAsm() []const u8 {
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
        \\add x0, sp, #{[frame]d}
        \\stp x30, x0, [sp, #{[x30]d}]
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #{[elr]d}]
        \\mrs x0, esr_el1
        \\mrs x1, far_el1
        \\stp x0, x1, [sp, #{[esr]d}]
        \\
    , .{ .frame = FULL_FRAME_SIZE, .x30 = OFF_X30, .elr = OFF_ELR, .esr = OFF_ESR });
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

test "genEntryAsm full save contains expected structure" {
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

test "genEntryAsm fast path omits callee-saved registers" {
    const asm_str = comptime genCallerSaveAsm();

    try std.testing.expect(mem.indexOf(u8, asm_str, "x0, x1") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "x18, x30") != null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "x19") == null);
    try std.testing.expect(mem.indexOf(u8, asm_str, "x28") == null);
}

test "save and restore have matching instruction counts" {
    const full_stp = comptime mem.count(u8, genFullSaveAsm(), "stp");
    const full_ldp = comptime mem.count(u8, genFullRestoreAsm(), "ldp");
    const fast_stp = comptime mem.count(u8, genCallerSaveAsm(), "stp");
    const fast_ldp = comptime mem.count(u8, genCallerRestoreAsm(), "ldp");

    try std.testing.expectEqual(full_stp, full_ldp);
    try std.testing.expectEqual(fast_stp, fast_ldp);
}

// Compile-time verification
comptime {
    // Verify frame sizes are 16-byte aligned (ARM64 ABI requirement)
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
    if (OFF_X30 != 240)
        @compileError("x30 offset mismatch - check regs array size");
    if (OFF_SP != 248)
        @compileError("sp_saved offset mismatch - assembly uses #248");
    if (OFF_ELR != 256)
        @compileError("elr offset mismatch - assembly uses #256");
    if (OFF_SPSR != 264)
        @compileError("spsr offset mismatch - assembly uses #264");
    if (OFF_ESR != 272)
        @compileError("esr offset mismatch - assembly uses #272");
    if (OFF_FAR != 280)
        @compileError("far offset mismatch - assembly uses #280");
}
