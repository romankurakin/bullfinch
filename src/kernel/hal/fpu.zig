//! Floating Point Unit HAL.
//!
//! Provides architecture-independent FPU context switching.
//! Architecture-specific save/restore policy lives in arch fpu backends.

const builtin = @import("builtin");

const hwinfo = @import("../hwinfo/hwinfo.zig");
const limits = @import("../limits.zig");
const trace = @import("../debug/trace.zig");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/fpu.zig"),
    .riscv64 => @import("../arch/riscv64/fpu.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const FpuState = arch.FpuState;
pub const save = arch.save;
pub const restore = arch.restore;
pub const enable = arch.enable;
pub const disable = arch.disable;
pub const isEnabled = arch.isEnabled;
pub const isDirty = arch.isDirty;
pub const initRegs = arch.init;
pub const bootInit = arch.bootInit;
pub const detect = arch.detect;
/// Trap classification for architecture trap handlers.
/// `oom` is reserved for future fallible state provisioning policies.
/// Current embedded per-thread state keeps this path unreachable.
/// TODO(pm-userspace): Route `oom` through userspace PM fault policy instead
/// of direct in-kernel termination once exception channels are implemented.
pub const TrapResult = enum { handled, not_fpu, oom };

const Thread = @import("../task/thread.zig").Thread;

/// Per-CPU FPU owner tracking. Null means no thread owns FPU on this CPU.
var fpu_owner: [limits.MAX_CPUS]?*Thread = [_]?*Thread{null} ** limits.MAX_CPUS;

/// Get current CPU's FPU owner.
inline fn getOwner(cpu_id: u32) ?*Thread {
    if (cpu_id >= limits.MAX_CPUS) return null;
    return fpu_owner[cpu_id];
}

/// Set current CPU's FPU owner.
inline fn setOwner(cpu_id: u32, owner: ?*Thread) void {
    if (cpu_id >= limits.MAX_CPUS) return;
    fpu_owner[cpu_id] = owner;
}

/// Called on context switch.
/// Architecture backend decides save/restore policy and whether `next`
/// becomes the current hardware owner.
pub fn onContextSwitch(cpu_id: u32, prev: *Thread, next: *Thread) void {
    if (!hwinfo.hasFpu()) return; // No FPU, nothing to do

    const next_owns = arch.onContextSwitch(&prev.fpu_state, &next.fpu_state);
    if (next_owns) {
        setOwner(cpu_id, next);
    }
}

/// Handle an FPU trap for `thread` on `cpu_id`.
/// Saves previous owner state when needed, restores current thread state, and
/// updates per-CPU owner tracking. Returns trap classification for caller policy.
pub fn handleTrap(thread: *Thread, cpu_id: u32) TrapResult {
    if (!hwinfo.hasFpu()) return .not_fpu; // No FPU hardware

    const prev_owner = getOwner(cpu_id);
    const switching_owner = prev_owner != thread;

    // Enable FPU first - needed to access FP registers for save/restore.
    enable();

    // Save previous owner's state before ownership transfer.
    const prev_state: ?*FpuState = if (prev_owner) |prev|
        if (switching_owner) &prev.fpu_state else null
    else
        null;
    if (prev_state) |state| save(state);

    // Thread owns embedded FPU state for its full lifetime.
    const thread_state = &thread.fpu_state;
    if (switching_owner) {
        restore(thread_state);
    }

    setOwner(cpu_id, thread);

    // third field kept for first-use tracing compatibility; preallocation keeps it zero.
    const prev_tid = if (prev_owner) |p| p.id else 0;
    if (comptime trace.debug_kernel) trace.emit(.fpu_trap, thread.id, prev_tid, 0);

    return .handled;
}

/// Called when thread exits: release FPU ownership if this thread owns it.
pub fn onThreadExit(thread: *Thread, cpu_id: u32) void {
    if (!hwinfo.hasFpu()) return; // No FPU, nothing to clean up

    if (getOwner(cpu_id) == thread) {
        setOwner(cpu_id, null);
        // State is embedded in Thread and dies with thread allocation.
    }
}

/// Execute a single FPU instruction. Used for FPU path tests.
/// Kernel is compiled with soft-float, so we use inline asm.
pub fn useFpuInstruction() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ .arch_extension fp
            \\ fmov d0, #1.0
        ),
        .riscv64 => asm volatile (
            \\ .option arch, +d
            \\ fmv.d.x f0, zero
        ),
        else => @compileError("Unsupported architecture"),
    }
}

comptime {
    if (!@hasDecl(FpuState, "SIZE")) @compileError("FpuState must have SIZE constant");
    if (!@hasDecl(arch, "save")) @compileError("arch must have save function");
    if (!@hasDecl(arch, "restore")) @compileError("arch must have restore function");
    if (!@hasDecl(arch, "enable")) @compileError("arch must have enable function");
    if (!@hasDecl(arch, "disable")) @compileError("arch must have disable function");
    if (!@hasDecl(arch, "isDirty")) @compileError("arch must have isDirty function");
    if (!@hasDecl(arch, "detect")) @compileError("arch must have detect function");
    if (!@hasDecl(arch, "onContextSwitch")) {
        @compileError("arch must have onContextSwitch function");
    }
}
