//! ARM64 Trap Frame.
//!
//! Defines the saved register layout during trap handling. The struct layout must
//! exactly match the assembly save/restore order in trap_entry.zig — any mismatch
//! causes silent register corruption. Comptime assertions verify critical offsets.
//!
//! Saves 31 GPRs (x0-x30), SP, and four system registers (ELR, SPSR, ESR, FAR).
//! Total size is 288 bytes, 16-byte aligned per AAPCS64.
//!
//! See ARM Architecture Reference Manual, D1.4 (Exceptions).

const std = @import("std");

/// Saved register context during trap. Layout must match assembly save/restore order.
/// ARM calling convention: x0-x7 arguments, x19-x28 callee-saved, x29 frame pointer, x30 link register.
pub const TrapFrame = extern struct {
    regs: [31]u64, // x0-x30
    sp_saved: u64, // Stack pointer at trap entry (kernel or user depending on origin)
    elr: u64, // Exception link register (return address)
    spsr: u64, // Saved program status register
    esr: u64, // Exception syndrome register (cause)
    far: u64, // Fault address register

    pub const FRAME_SIZE = @sizeOf(TrapFrame);

    comptime {
        if (FRAME_SIZE != 288) @compileError("TrapFrame size changed - update assembly!");
    }

    /// Program counter at trap (exception return address).
    pub inline fn pc(self: *const TrapFrame) usize {
        return self.elr;
    }

    /// Set program counter for exception return.
    pub inline fn setPc(self: *TrapFrame, value: usize) void {
        self.elr = value;
    }

    /// Stack pointer at trap.
    pub inline fn sp(self: *const TrapFrame) usize {
        return self.sp_saved;
    }

    /// Raw cause value (ESR_EL1 on ARM64).
    pub inline fn cause(self: *const TrapFrame) usize {
        return self.esr;
    }

    /// Fault address for memory aborts.
    pub inline fn faultAddr(self: *const TrapFrame) usize {
        return self.far;
    }

    /// Frame pointer at trap (x29 on ARM64).
    pub inline fn fp(self: *const TrapFrame) usize {
        return self.regs[29];
    }

    /// Check if trap originated from user mode (EL0).
    /// SPSR.M[3:0] encodes the exception level: 0b0000 = EL0.
    pub inline fn isFromUser(self: *const TrapFrame) bool {
        return (self.spsr & 0xF) == 0;
    }

    /// Get general-purpose register value by index (x0-x30).
    /// Returns 0 for invalid index.
    pub inline fn getReg(self: *const TrapFrame, idx: usize) u64 {
        if (idx >= 31) return 0;
        return self.regs[idx];
    }

    // Syscall ABI (AAPCS64): number in x8, args in x0-x5, return in x0.

    /// Get syscall number (x8 register).
    pub inline fn syscallNum(self: *const TrapFrame) usize {
        return self.regs[8];
    }

    /// Get syscall argument by index (0-5 maps to x0-x5).
    pub inline fn syscallArg(self: *const TrapFrame, n: u3) usize {
        if (n > 5) return 0;
        return self.regs[n];
    }

    /// Set syscall return value (x0 register).
    pub inline fn setSyscallRet(self: *TrapFrame, value: usize) void {
        self.regs[0] = value;
    }
};

/// Read previous frame pointer and return address from stack frame.
/// ARM64 frame layout: [fp+0]=prev_fp, [fp+8]=ra.
pub inline fn readStackFrame(fp: usize) struct { usize, usize } {
    const ptr: *const [2]usize = @ptrFromInt(fp);
    return .{ ptr[0], ptr[1] };
}

test "TrapFrame.FRAME_SIZE is 288 bytes" {
    try std.testing.expectEqual(@as(usize, 288), TrapFrame.FRAME_SIZE);
}

test "TrapFrame.getReg returns correct values" {
    var frame: TrapFrame = undefined;
    for (0..31) |i| {
        frame.regs[i] = @as(u64, i) + 100;
    }

    try std.testing.expectEqual(@as(u64, 100), frame.getReg(0));
    try std.testing.expectEqual(@as(u64, 101), frame.getReg(1));
    try std.testing.expectEqual(@as(u64, 130), frame.getReg(30));
    try std.testing.expectEqual(@as(u64, 0), frame.getReg(31)); // out of bounds
}

test "TrapFrame.isFromUser detects EL0" {
    var frame: TrapFrame = undefined;
    frame.spsr = 0x00; // EL0
    try std.testing.expect(frame.isFromUser());

    frame.spsr = 0x05; // EL1h
    try std.testing.expect(!frame.isFromUser());
}

test "TrapFrame syscall accessors" {
    var frame: TrapFrame = undefined;
    frame.regs[8] = 42; // syscall number
    frame.regs[0] = 100;
    frame.regs[1] = 200;
    frame.regs[5] = 500;

    try std.testing.expectEqual(@as(usize, 42), frame.syscallNum());
    try std.testing.expectEqual(@as(usize, 100), frame.syscallArg(0));
    try std.testing.expectEqual(@as(usize, 200), frame.syscallArg(1));
    try std.testing.expectEqual(@as(usize, 500), frame.syscallArg(5));

    frame.setSyscallRet(999);
    try std.testing.expectEqual(@as(u64, 999), frame.regs[0]);
}
