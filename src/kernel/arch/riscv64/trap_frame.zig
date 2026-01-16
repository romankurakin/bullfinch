//! RISC-V Trap Frame.
//!
//! Defines the saved register layout during trap handling. The struct layout must
//! exactly match the assembly save/restore order in trap_entry.zig — any mismatch
//! causes silent register corruption. Comptime assertions verify critical offsets.
//!
//! Saves 31 GPRs (x1-x31, x0 is hardwired zero), SP, and four CSRs (sepc, sstatus,
//! scause, stval). Total size is 288 bytes, 16-byte aligned per RISC-V ABI.
//!
//! See RISC-V Privileged Specification, Chapter 12 (Supervisor-Level ISA).

const std = @import("std");
const dispatch = @import("../../trap/dispatch.zig");

const TrapKind = dispatch.TrapKind;
const TrapInfo = dispatch.TrapInfo;

/// Saved register context during trap. Layout must match assembly save/restore order.
/// RISC-V calling convention: a0-a7 arguments, s0-s11 callee-saved, ra return address.
pub const TrapFrame = extern struct {
    regs: [31]u64, // x1-x31 (x0 is hardwired zero)
    sp_saved: u64, // Original stack pointer (before trap adjusted SP)
    sepc: u64, // Exception PC (return address)
    sstatus: u64, // Status (privilege, interrupt enable)
    scause: u64, // Cause (bit 63: interrupt, lower: code)
    stval: u64, // Trap value (fault address or instruction)

    pub const FRAME_SIZE = @sizeOf(TrapFrame);

    comptime {
        if (FRAME_SIZE != 288) @compileError("TrapFrame size changed - update assembly!");
    }

    /// Program counter at trap (exception PC).
    pub inline fn pc(self: *const TrapFrame) usize {
        return self.sepc;
    }

    /// Set program counter for exception return.
    pub inline fn setPc(self: *TrapFrame, value: usize) void {
        self.sepc = value;
    }

    /// Stack pointer at trap.
    pub inline fn sp(self: *const TrapFrame) usize {
        return self.sp_saved;
    }

    /// Raw cause value (scause on RISC-V).
    pub inline fn cause(self: *const TrapFrame) usize {
        return self.scause;
    }

    /// Fault address for memory exceptions.
    pub inline fn faultAddr(self: *const TrapFrame) usize {
        return self.stval;
    }

    /// Check if trap originated from user mode.
    /// sstatus.SPP (bit 8) is 0 for user mode, 1 for supervisor mode.
    pub inline fn isFromUser(self: *const TrapFrame) bool {
        return (self.sstatus & 0x100) == 0;
    }

    /// Get register value by index (x0-x31).
    /// x0 returns 0 (hardwired), x2 returns saved SP.
    pub inline fn getReg(self: *const TrapFrame, idx: usize) u64 {
        if (idx == 0) return 0; // x0 is always zero
        if (idx > 31) return 0; // out of bounds
        if (idx == 2) return self.sp_saved; // x2/sp: return original
        return self.regs[idx - 1];
    }

    // Syscall ABI (RISC-V): number in a7, args in a0-a5, return in a0.

    /// Get syscall number (a7/x17 register).
    pub inline fn syscallNum(self: *const TrapFrame) usize {
        return self.regs[16]; // x17 is at regs[16] (x1 is regs[0])
    }

    /// Get syscall argument by index (0-5 maps to a0-a5/x10-x15).
    pub inline fn syscallArg(self: *const TrapFrame, n: u3) usize {
        if (n > 5) return 0;
        return self.regs[9 + n]; // x10 is at regs[9]
    }

    /// Set syscall return value (a0/x10 register).
    pub inline fn setSyscallRet(self: *TrapFrame, value: usize) void {
        self.regs[9] = value; // x10 is at regs[9]
    }
};

/// RISC-V trap cause codes from scause register.
/// Bit 63 distinguishes interrupts (1) from exceptions (0).
const INTERRUPT_BIT: u64 = 1 << 63;

const ExceptionCode = enum(u64) {
    instruction_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_misaligned = 4,
    load_access_fault = 5,
    store_misaligned = 6,
    store_access_fault = 7,
    ecall_from_u = 8,
    ecall_from_s = 9,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    // Interrupts (with INTERRUPT_BIT set)
    supervisor_software = INTERRUPT_BIT | 1,
    supervisor_timer = INTERRUPT_BIT | 5,
    supervisor_external = INTERRUPT_BIT | 9,
    _,
};

/// Classify trap into architecture-independent kind.
pub fn classify(frame: *const TrapFrame) TrapInfo {
    const code: ExceptionCode = @enumFromInt(frame.scause);

    return switch (code) {
        .ecall_from_u, .ecall_from_s => .{ .kind = .syscall },
        .instruction_page_fault => .{ .kind = .page_fault, .aux = frame.stval },
        .load_page_fault => .{ .kind = .page_fault, .aux = frame.stval },
        .store_page_fault => .{ .kind = .page_fault, .aux = frame.stval },
        .instruction_misaligned => .{ .kind = .alignment_fault, .aux = frame.stval },
        .load_misaligned => .{ .kind = .alignment_fault, .aux = frame.stval },
        .store_misaligned => .{ .kind = .alignment_fault, .aux = frame.stval },
        .illegal_instruction => .{ .kind = .illegal_instruction, .aux = frame.stval },
        .breakpoint => .{ .kind = .breakpoint },
        .supervisor_timer => .{ .kind = .timer_irq },
        .supervisor_external => .{ .kind = .external_irq },
        .supervisor_software => .{ .kind = .software_irq },
        else => .{ .kind = .unknown },
    };
}

test "TrapFrame.FRAME_SIZE is 288 bytes" {
    try std.testing.expectEqual(@as(usize, 288), TrapFrame.FRAME_SIZE);
}

test "TrapFrame.getReg handles special cases" {
    var frame: TrapFrame = undefined;
    for (0..31) |i| {
        frame.regs[i] = @as(u64, i) + 100;
    }
    frame.sp_saved = 0xDEADBEEF;

    // x0 always returns 0
    try std.testing.expectEqual(@as(u64, 0), frame.getReg(0));
    // x1 (ra) comes from regs[0]
    try std.testing.expectEqual(@as(u64, 100), frame.getReg(1));
    // x2 (sp) returns saved SP
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), frame.getReg(2));
    // x3+ come from regs array
    try std.testing.expectEqual(@as(u64, 102), frame.getReg(3));
    // Out of bounds
    try std.testing.expectEqual(@as(u64, 0), frame.getReg(32));
}

test "TrapFrame.isFromUser detects U-mode" {
    var frame: TrapFrame = undefined;
    frame.sstatus = 0x00; // SPP = 0 (U-mode)
    try std.testing.expect(frame.isFromUser());

    frame.sstatus = 0x100; // SPP = 1 (S-mode)
    try std.testing.expect(!frame.isFromUser());
}

test "TrapFrame syscall accessors" {
    var frame: TrapFrame = undefined;
    // a7 = x17 = regs[16]
    frame.regs[16] = 42;
    // a0-a5 = x10-x15 = regs[9-14]
    frame.regs[9] = 100; // a0
    frame.regs[10] = 200; // a1
    frame.regs[14] = 500; // a5

    try std.testing.expectEqual(@as(usize, 42), frame.syscallNum());
    try std.testing.expectEqual(@as(usize, 100), frame.syscallArg(0));
    try std.testing.expectEqual(@as(usize, 200), frame.syscallArg(1));
    try std.testing.expectEqual(@as(usize, 500), frame.syscallArg(5));

    frame.setSyscallRet(999);
    try std.testing.expectEqual(@as(u64, 999), frame.regs[9]);
}

test "classify identifies ecall as syscall" {
    var frame: TrapFrame = undefined;
    frame.scause = 8; // ecall_from_u
    const info = classify(&frame);
    try std.testing.expectEqual(TrapKind.syscall, info.kind);
}

test "classify identifies page fault" {
    var frame: TrapFrame = undefined;
    frame.scause = 13; // load_page_fault
    frame.stval = 0xCAFEBABE;
    const info = classify(&frame);
    try std.testing.expectEqual(TrapKind.page_fault, info.kind);
    try std.testing.expectEqual(@as(usize, 0xCAFEBABE), info.aux);
}

test "classify identifies timer interrupt" {
    var frame: TrapFrame = undefined;
    frame.scause = INTERRUPT_BIT | 5; // supervisor_timer
    const info = classify(&frame);
    try std.testing.expectEqual(TrapKind.timer_irq, info.kind);
}
