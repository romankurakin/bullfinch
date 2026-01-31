//! Floating Point Unit HAL.
//!
//! Provides architecture-independent lazy FPU context switching.
//! Threads don't get FPU access by default; on first FPU instruction,
//! we trap, save previous owner's state, and grant access to new owner.
//!
//! This saves ~500 bytes of register save/restore per context switch
//! for threads that don't use floating point.

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
/// ARM64: Disable FPU so new thread traps on first use (lazy save).
/// RISC-V: Save current thread's state if dirty (eager save with dirty tracking).
pub fn onContextSwitch(cpu_id: u32) void {
    if (!hwinfo.hasFpu()) return; // No FPU, nothing to do

    // On RISC-V, disable() is a no-op. We use dirty tracking instead.
    // Save current owner's state if dirty before switching.
    if (builtin.cpu.arch == .riscv64) {
        if (getOwner(cpu_id)) |owner| {
            if (owner.fpu_state) |state| {
                if (isDirty()) {
                    save(state);
                    // save() sets FS=Clean, resetting dirty tracking
                }
            }
        }
    }
    disable();
}

/// Handle FPU trap: save previous owner's state, restore/init new owner's state.
/// Returns true if handled, false if not an FPU trap.
pub fn handleTrap(thread: *Thread, cpu_id: u32) bool {
    if (!hwinfo.hasFpu()) return false; // No FPU hardware

    const prev_owner = getOwner(cpu_id);
    const first_use = thread.fpu_state == null;

    // Enable FPU first - needed to access FP registers for save/restore.
    enable();

    // Save previous owner's state if different thread.
    if (prev_owner) |prev| {
        if (prev != thread) {
            if (prev.fpu_state) |state| {
                save(state);
            }
        }
    }

    // Restore or initialize new owner's state.
    if (thread.fpu_state) |state| {
        if (prev_owner != thread) {
            restore(state);
        }
        // Else: same thread, state already in registers.
    } else {
        // First FPU use: allocate state and initialize registers.
        thread.fpu_state = allocFpuState() orelse {
            // OOM: can't use FPU. Caller should terminate thread.
            // Returning false will cause panic, which is better than silent loop.
            disable();
            return false;
        };
        initRegs();
    }

    setOwner(cpu_id, thread);

    // Trace: tid, prev_owner_tid, first_use (1 = newly allocated, 0 = restored)
    const prev_tid = if (prev_owner) |p| p.id else 0;
    trace.emit(.fpu_trap, thread.id, prev_tid, if (first_use) 1 else 0);

    return true;
}

/// Called when thread exits: release FPU ownership if this thread owns it.
pub fn onThreadExit(thread: *Thread, cpu_id: u32) void {
    if (!hwinfo.hasFpu()) return; // No FPU, nothing to clean up

    if (getOwner(cpu_id) == thread) {
        setOwner(cpu_id, null);
        // State will be freed with thread, no need to save.
    }
    // Free FPU state if allocated.
    if (thread.fpu_state) |state| {
        freeFpuState(state);
        thread.fpu_state = null;
    }
}

// Simple FPU state allocator using kernel allocator.
const allocator = @import("../allocator/allocator.zig");

fn allocFpuState() ?*FpuState {
    const bytes = allocator.alloc(FpuState.SIZE, @alignOf(FpuState)) catch return null;
    const state: *FpuState = @ptrCast(@alignCast(bytes));
    state.* = .{};
    return state;
}

fn freeFpuState(state: *FpuState) void {
    const bytes: *u8 = @ptrCast(state);
    allocator.free(bytes) catch {};
}

/// Execute a single FPU instruction. Used for testing lazy FPU.
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
}
