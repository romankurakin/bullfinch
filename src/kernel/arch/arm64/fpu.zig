//! ARM64 Lazy FPU Context Switching.
//!
//! Traps FPU/SIMD access via CPACR_EL1.FPEN (bits 21:20). On first FPU use,
//! hardware generates EC=0x07 trap; we save previous owner's state, restore
//! new owner's state, then enable access. This avoids 528-byte save/restore
//! on every context switch for threads that never use floating point.
//!
//! FPU state: 32 x 128-bit V registers + FPCR + FPSR = 528 bytes.
//!
//! See ARM Architecture Reference Manual, D24.2.36 (CPACR_EL1).

const std = @import("std");

/// FPU register state (528 bytes). Control registers at offset 0 for stp/ldp.
pub const FpuState = extern struct {
    /// Floating-point Control Register.
    fpcr: u64 = 0,
    /// Floating-point Status Register.
    fpsr: u64 = 0,
    /// V0-V31 (128-bit SIMD/FP registers, stored as pairs of u64).
    v: [32][2]u64 align(16) = [_][2]u64{.{ 0, 0 }} ** 32,

    pub const SIZE: usize = 528;

    comptime {
        if (@sizeOf(FpuState) != SIZE) @compileError("FpuState size mismatch");
    }
};

/// CPACR_EL1.FPEN field (bits 21:20). See ARM Architecture Reference Manual, D24.2.36.
const Fpen = enum(u2) {
    trap_all = 0b00,
    trap_el0 = 0b01,
    trap_all_alt = 0b10,
    no_trap = 0b11,
};

const FPEN_SHIFT: u6 = 20;
const FPEN_MASK: u64 = 0b11 << FPEN_SHIFT;

/// Disable FPU access, causing trap on next FPU instruction.
pub fn disable() void {
    var cpacr = asm volatile ("mrs %[ret], cpacr_el1"
        : [ret] "=r" (-> u64),
    );
    cpacr = (cpacr & ~FPEN_MASK) | (@as(u64, @intFromEnum(Fpen.trap_all)) << FPEN_SHIFT);
    asm volatile ("msr cpacr_el1, %[val]\nisb"
        :
        : [val] "r" (cpacr),
    );
}

/// Enable FPU access for current thread.
pub fn enable() void {
    var cpacr = asm volatile ("mrs %[ret], cpacr_el1"
        : [ret] "=r" (-> u64),
    );
    cpacr = (cpacr & ~FPEN_MASK) | (@as(u64, @intFromEnum(Fpen.no_trap)) << FPEN_SHIFT);
    asm volatile ("msr cpacr_el1, %[val]\nisb"
        :
        : [val] "r" (cpacr),
    );
}

/// Check if FPU is currently enabled.
pub fn isEnabled() bool {
    const cpacr = asm volatile ("mrs %[ret], cpacr_el1"
        : [ret] "=r" (-> u64),
    );
    const fpen: u2 = @truncate((cpacr >> FPEN_SHIFT) & 0b11);
    return fpen == @intFromEnum(Fpen.no_trap);
}

/// Returns true (ARM64 uses lazy trapping, not dirty tracking).
pub fn isDirty() bool {
    return true;
}

const OFF_FPCR = @offsetOf(FpuState, "fpcr");
const OFF_V = @offsetOf(FpuState, "v");

comptime {
    if (OFF_FPCR != 0) @compileError("FpuState.fpcr must be at offset 0");
    if (@offsetOf(FpuState, "fpsr") != 8) @compileError("FpuState.fpsr must be at offset 8");
    if (OFF_V != 16) @compileError("FpuState.v must be at offset 16");
    if (@sizeOf(FpuState) != 528) @compileError("FpuState size must be 528 bytes");
}

/// Generate stp/ldp for Q register pairs.
fn genQRegsAsm(comptime op: []const u8) []const u8 {
    comptime {
        var asm_str: []const u8 = "";
        var i: usize = 0;
        while (i < 32) : (i += 2) {
            const offset = OFF_V + i * 16;
            asm_str = asm_str ++ std.fmt.comptimePrint(
                "{s} q{d}, q{d}, [%[state], #{d}]\n",
                .{ op, i, i + 1, offset },
            );
        }
        return asm_str;
    }
}

/// Generate init: zero v0, copy to v1-v31.
fn genInitAsm() []const u8 {
    comptime {
        var asm_str: []const u8 = "msr fpcr, xzr\nmsr fpsr, xzr\nmovi v0.2d, #0\n";
        for (1..32) |i| {
            asm_str = asm_str ++ std.fmt.comptimePrint("mov v{d}.16b, v0.16b\n", .{i});
        }
        return asm_str;
    }
}

/// Save FPU registers to memory.
pub fn save(state: *FpuState) void {
    asm volatile (".arch_extension fp\n.arch_extension simd\n" ++
            "mrs x0, fpcr\nmrs x1, fpsr\nstp x0, x1, [%[state]]\n" ++
            genQRegsAsm("stp")
        :
        : [state] "r" (state),
        : .{ .x0 = true, .x1 = true, .memory = true });
}

/// Restore FPU registers from memory.
pub fn restore(state: *const FpuState) void {
    asm volatile (".arch_extension fp\n.arch_extension simd\n" ++
            "ldp x0, x1, [%[state]]\nmsr fpcr, x0\nmsr fpsr, x1\n" ++
            genQRegsAsm("ldp")
        :
        : [state] "r" (state),
        : .{ .x0 = true, .x1 = true, .memory = true });
}

/// Initialize FPU registers to zero.
pub fn init() void {
    asm volatile (".arch_extension fp\n.arch_extension simd\n" ++ genInitAsm());
}

/// Boot-time init: ensure FPU trapping enabled for lazy switching.
pub fn bootInit() void {
    if (!detect()) return;
    disable();
}

/// Check ID_AA64PFR0_EL1.FP (bits 19:16). 0b1111 = not implemented.
/// See ARM Architecture Reference Manual, D24.2.93.
pub fn detect() bool {
    const id_aa64pfr0 = asm volatile ("mrs %[ret], id_aa64pfr0_el1"
        : [ret] "=r" (-> u64),
    );
    const fp_field: u4 = @truncate((id_aa64pfr0 >> 16) & 0xF);
    return fp_field != 0b1111;
}

/// ARM64 lazy path: disable FPU so next thread traps on first use.
/// Returns false because FPU owner does not change until a trap occurs.
pub fn onContextSwitch(prev_state: *FpuState, next_state: *FpuState) bool {
    _ = prev_state;
    _ = next_state;
    disable();
    return false;
}
