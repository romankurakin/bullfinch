//! RISC-V FPU Support.
//!
//! OpenSBI does not delegate illegal_instruction to S-mode (medeleg[2]=0),
//! so sstatus.FS=Off won't trap to our kernel. We use eager context switching
//! with hardware dirty tracking instead:
//! - FPU always enabled (FS=Clean or Dirty, never Off)
//! - Context switch: save only if FS=Dirty, then set FS=Clean
//! - Restore: load state and set FS=Clean
//!
//! FPU state: 32 x 64-bit F registers + fcsr = 264 bytes.
//!
//! See RISC-V Privileged Specification, Section 3.1.6.7 (Extension Context Status).

const std = @import("std");

/// FPU register state (264 bytes).
pub const FpuState = extern struct {
    /// f0-f31 (64-bit FP registers).
    f: [32]u64 align(8) = [_]u64{0} ** 32,
    /// Floating-point Control and Status Register.
    fcsr: u64 = 0,

    pub const SIZE: usize = 264;

    comptime {
        if (@sizeOf(FpuState) != SIZE) @compileError("FpuState size mismatch");
    }
};

/// sstatus.FS field (bits 14:13). See RISC-V Privileged Specification, Table 11.
const FsStatus = enum(u2) {
    off = 0,
    initial = 1,
    clean = 2,
    dirty = 3,
};

const FS_SHIFT: u6 = 13;
const FS_MASK: u64 = 0b11 << FS_SHIFT;

/// No-op on RISC-V (can't trap without medeleg[2] delegation).
pub fn disable() void {}

/// Enable FPU access (set FS=Clean).
pub fn enable() void {
    asm volatile (
        \\ csrc sstatus, %[mask]
        \\ csrs sstatus, %[clean]
        :
        : [mask] "r" (FS_MASK),
          [clean] "r" (@as(u64, @intFromEnum(FsStatus.clean)) << FS_SHIFT),
    );
}

/// Check if FPU enabled (FS != Off).
pub fn isEnabled() bool {
    return getFs() != .off;
}

/// Check if FPU state dirty (FS=Dirty).
pub fn isDirty() bool {
    return getFs() == .dirty;
}

/// Read FS field from sstatus.
inline fn getFs() FsStatus {
    const sstatus = asm volatile ("csrr %[ret], sstatus"
        : [ret] "=r" (-> u64),
    );
    return @enumFromInt(@as(u2, @truncate((sstatus >> FS_SHIFT) & 0b11)));
}

/// Set FS=Clean (reset dirty tracking).
fn setClean() void {
    asm volatile (
        \\ csrc sstatus, %[mask]
        \\ csrs sstatus, %[clean]
        :
        : [mask] "r" (FS_MASK),
          [clean] "r" (@as(u64, @intFromEnum(FsStatus.clean)) << FS_SHIFT),
    );
}

const OFF_F = @offsetOf(FpuState, "f");
const OFF_FCSR = @offsetOf(FpuState, "fcsr");

comptime {
    if (OFF_F != 0) @compileError("FpuState.f must be at offset 0");
    if (OFF_FCSR != 256) @compileError("FpuState.fcsr must be at offset 256");
    if (@sizeOf(FpuState) != 264) @compileError("FpuState size must be 264 bytes");
}

/// Generate fsd/fld for all 32 FP registers.
fn genFpRegsAsm(comptime op: []const u8) []const u8 {
    comptime {
        var asm_str: []const u8 = "";
        for (0..32) |i| {
            const offset = OFF_F + i * 8;
            asm_str = asm_str ++ std.fmt.comptimePrint("{s} f{d}, {d}(%[state])\n", .{ op, i, offset });
        }
        return asm_str;
    }
}

/// Generate init assembly: zero f0, then copy to f1-f31.
fn genInitAsm() []const u8 {
    comptime {
        var asm_str: []const u8 = "fscsr zero\nfmv.d.x f0, zero\n";
        for (1..32) |i| {
            asm_str = asm_str ++ std.fmt.comptimePrint("fsgnj.d f{d}, f0, f0\n", .{i});
        }
        return asm_str;
    }
}

/// Save FPU registers to state struct and set FS=Clean.
/// After save, state matches memory so dirty tracking resets.
pub fn save(state: *FpuState) void {
    asm volatile (".option arch, +d\n" ++ genFpRegsAsm("fsd") ++
            std.fmt.comptimePrint("frcsr t0\nsd t0, {d}(%[state])\n", .{OFF_FCSR})
        :
        : [state] "r" (state),
        : .{ .x5 = true, .memory = true });
    setClean();
}

/// Restore FPU registers from state struct and set FS=Clean.
/// After restore, state matches memory so dirty tracking resets.
pub fn restore(state: *const FpuState) void {
    asm volatile (".option arch, +d\n" ++ genFpRegsAsm("fld") ++
            std.fmt.comptimePrint("ld t0, {d}(%[state])\nfscsr t0\n", .{OFF_FCSR})
        :
        : [state] "r" (state),
        : .{ .x5 = true, .memory = true });
    setClean();
}

/// Initialize FPU to clean state (all zeros).
pub fn init() void {
    asm volatile (".option arch, +d\n" ++ genInitAsm());
}

/// Boot-time FPU initialization. Enables FPU for kernel use.
/// Must be called before any FPU-using code runs.
pub fn bootInit() void {
    if (!detect()) return; // No FPU, nothing to enable
    enable(); // Enable FPU access (set FS=Clean)
}

/// Detect if FPU is available by checking if sstatus.FS is writable.
/// If FS is read-only zero, no FPU is implemented.
/// See RISC-V Privileged Specification, Section 3.1.6.7.
pub fn detect() bool {
    // Try to set FS=Initial (non-zero value)
    const test_val: u64 = @as(u64, @intFromEnum(FsStatus.initial)) << FS_SHIFT;
    asm volatile ("csrs sstatus, %[val]"
        :
        : [val] "r" (test_val),
    );

    // Read back - if FS is still zero, no FPU
    const sstatus = asm volatile ("csrr %[ret], sstatus"
        : [ret] "=r" (-> u64),
    );
    const fs: u2 = @truncate((sstatus >> FS_SHIFT) & 0b11);

    if (fs == 0) {
        return false; // FS is read-only zero, no FPU
    }

    // Clear FS back to Off for clean state
    asm volatile ("csrc sstatus, %[mask]"
        :
        : [mask] "r" (FS_MASK),
    );
    return true;
}
