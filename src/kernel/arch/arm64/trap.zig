//! ARM64 Trap Handling.
//!
//! Exception vector table: 4 types (Sync, IRQ, FIQ, SError) x 4 sources
//! (Current EL SP0/SPx, Lower EL AArch64/AArch32) = 16 entries. Each entry
//! is 128 bytes; table must be 2KB aligned per VBAR_EL1 requirements.
//!
//! Hardware saves ELR_EL1 and SPSR_EL1, masks interrupts, then jumps to vector.
//! We save remaining registers in trap_entry.zig. Kernel traps use SP_EL1;
//! user traps read SP_EL0 for the user stack pointer.
//!
//! See ARM Architecture Reference Manual, D1.4 (Exceptions).
//!
//! TODO(syscall): Fast path dispatch for no pending work.
//! TODO(smp): Per-CPU trap state for reentry tracking.

const backtrace = @import("../../trap/backtrace.zig");
const clock = @import("../../clock/clock.zig");
const console = @import("../../console/console.zig");
const hal_fpu = @import("../../hal/fpu.zig");
const task = @import("../../task/task.zig");
const trace = @import("../../debug/trace.zig");
const cpu = @import("cpu.zig");
const fmt = @import("../../trap/fmt.zig");
const gic = @import("gic.zig");
const trap_entry = @import("trap_entry.zig");
const trap_frame = @import("trap_frame.zig");

// printUnsafe: can't acquire locks in trap context
const print = console.printUnsafe;

/// Saved register context. Layout must match assembly.
const TrapFrame = trap_frame.TrapFrame;

/// Exception class from ESR_EL1[31:26]. See ARM Architecture Reference Manual, D24.2.45.
pub const TrapClass = enum(u6) {
    unknown = 0x00,
    wfi_wfe = 0x01,
    cp15_mcr_mrc = 0x03,
    cp15_mcrr_mrrc = 0x04,
    cp14_mcr_mrc = 0x05,
    cp14_ldc_stc = 0x06,
    simd_fp = 0x07,
    cp10_id = 0x08,
    ptrauth = 0x09,
    cp14_mrrc = 0x0C,
    branch_target = 0x0D,
    illegal_state = 0x0E,
    svc_aarch32 = 0x11,
    hvc_aarch32 = 0x12,
    smc_aarch32 = 0x13,
    svc_aarch64 = 0x15,
    hvc_aarch64 = 0x16,
    smc_aarch64 = 0x17,
    msr_mrs_sys = 0x18,
    sve = 0x19,
    eret = 0x1A,
    pac_fail = 0x1C,
    sme = 0x1D,
    imp_def = 0x1F,
    inst_abort_lower = 0x20,
    inst_abort_same = 0x21,
    pc_align = 0x22,
    data_abort_lower = 0x24,
    data_abort_same = 0x25,
    sp_align = 0x26,
    mops = 0x27,
    fp_aarch32 = 0x28,
    fp_aarch64 = 0x2C,
    gcs = 0x2D,
    serror = 0x2F,
    breakpoint_lower = 0x30,
    breakpoint_same = 0x31,
    step_lower = 0x32,
    step_same = 0x33,
    watchpoint_lower = 0x34,
    watchpoint_same = 0x35,
    bkpt_aarch32 = 0x38,
    vector_catch = 0x3A,
    brk_aarch64 = 0x3C,
    _,

    pub fn name(self: TrapClass) []const u8 {
        return switch (self) {
            .unknown => "unknown exception",
            .wfi_wfe => "wfi/wfe trapped",
            .simd_fp => "simd/fp access",
            .svc_aarch32 => "svc (syscall, aarch32)",
            .hvc_aarch32 => "hvc (hypervisor call, aarch32)",
            .smc_aarch32 => "smc (secure monitor call, aarch32)",
            .svc_aarch64 => "svc (syscall)",
            .hvc_aarch64 => "hvc (hypervisor call)",
            .smc_aarch64 => "smc (secure monitor call)",
            .msr_mrs_sys => "msr/mrs/sys trapped",
            .inst_abort_lower => "instruction abort (lower level)",
            .inst_abort_same => "instruction abort (same level)",
            .pc_align => "program counter alignment fault",
            .data_abort_lower => "data abort (lower level)",
            .data_abort_same => "data abort (same level)",
            .sp_align => "stack pointer alignment fault",
            .serror => "system error",
            .breakpoint_lower => "breakpoint (lower level)",
            .breakpoint_same => "breakpoint (same level)",
            .brk_aarch64 => "brk instruction",
            else => "other exception",
        };
    }
};

/// VBAR_EL1 requires 2KB alignment (bits 10:0 RES0).
const VBAR_ALIGNMENT = 2048;

/// Trap vector table. 16 entries × 128 bytes, 2KB aligned.
export fn trap_vectors() align(VBAR_ALIGNMENT) linksection(".vectors") callconv(.naked) void {
    asm volatile (
    // Current EL with SP_EL0 (0x000-0x1FF)
        \\ b kernelTrapEntry
        \\ .balign 128
        \\ b kernelIrqEntry
        \\ .balign 128
        \\ b kernelTrapEntry
        \\ .balign 128
        \\ b kernelTrapEntry
        \\ .balign 128
        // Current EL with SP_ELx (0x200-0x3FF)
        \\ b kernelTrapEntry
        \\ .balign 128
        \\ b kernelIrqEntry
        \\ .balign 128
        \\ b kernelTrapEntry
        \\ .balign 128
        \\ b kernelTrapEntry
        \\ .balign 128
        // Lower EL AArch64 (0x400-0x5FF)
        \\ b userTrapEntry
        \\ .balign 128
        \\ b userTrapEntry
        \\ .balign 128
        \\ b userTrapEntry
        \\ .balign 128
        \\ b userTrapEntry
        \\ .balign 128
        // Lower EL AArch32 (0x600-0x7FF)
        \\ b userTrapEntry
        \\ .balign 128
        \\ b userTrapEntry
        \\ .balign 128
        \\ b userTrapEntry
        \\ .balign 128
        \\ b userTrapEntry
        \\ .balign 128
    );
}

/// Kernel trap entry. Full save; kernel faults are bugs.
export fn kernelTrapEntry() callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleKernelTrap",
            .pass_frame = true,
        }));
}

/// Kernel IRQ entry. Full save for preemption safety.
export fn kernelIrqEntry() callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleKernelIrq",
            .pass_frame = false,
            .check_preempt = true,
        }));
}

/// User trap entry. Saves SP_EL0 (user stack).
export fn userTrapEntry() callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleUserTrap",
            .pass_frame = true,
            .save_sp_el0 = true,
            .check_preempt = true,
        }));
}

/// Spurious interrupt ID (GIC returns this when no interrupt pending).
const SPURIOUS_INTID: u32 = 1023;

const TIMER_PPI = gic.TIMER_PPI;

/// Kernel IRQ handler. Acknowledge, dispatch, end-of-interrupt.
/// Note: No frame available (fast path) - only prints IRQ ID on panic.
export fn handleKernelIrq() void {
    const intid = gic.acknowledge();
    if (intid == SPURIOUS_INTID) return;
    if (comptime trace.debug_kernel) trace.emit(.trap_enter, intid, 0, 0);

    switch (intid) {
        TIMER_PPI => clock.handleTimerIrq(),
        else => panicKernelIrq(intid),
    }

    gic.endOfInterrupt(intid);
    if (comptime trace.debug_kernel) trace.emit(.trap_exit, intid, 0, 0);
    // Preemption handled by check_preempt in assembly epilogue.
}

/// Print minimal panic for unhandled kernel IRQ (no frame available).
fn panicKernelIrq(intid: u32) noreturn {
    _ = cpu.disableInterrupts();

    print("\n[panic] unhandled kernel IRQ\n\n");
    printField("intid", intid);

    cpu.halt();
}

/// Kernel trap handler. Most kernel faults are bugs, but FPU traps are expected.
export fn handleKernelTrap(frame: *TrapFrame) callconv(.c) void {
    const ec_bits: u6 = @truncate(frame.esr >> 26);
    const ec: TrapClass = @enumFromInt(ec_bits);
    if (comptime trace.debug_kernel) trace.emit(.trap_enter, frame.pc(), @intFromEnum(ec), 0);

    switch (ec) {
        .simd_fp => switch (tryHandleFpuTrap()) {
            .handled => return,
            .oom => panicTrap(frame, "fpu state unavailable"),
            .not_fpu => {},
        },
        else => {},
    }
    // TODO(syscall): Handle SVC exceptions.
    // TODO(vm): Handle page faults.
    panicTrap(frame, ec.name());
}

/// User trap handler. Unified entry for all user-mode traps and interrupts.
/// TODO(pm-userspace): Forward user faults to userspace PM/exception handler.
/// TODO(signals): Deliver signal to userspace exception handler.
export fn handleUserTrap(frame: *TrapFrame) void {
    // If a pending IRQ is latched, handle it; otherwise treat as sync exception.
    const intid = gic.acknowledge();
    if (intid != SPURIOUS_INTID) {
        if (comptime trace.debug_kernel) trace.emit(.trap_enter, intid, 0, 1);
        switch (intid) {
            TIMER_PPI => clock.handleTimerIrq(),
            else => panicIrq(frame, intid),
        }
        gic.endOfInterrupt(intid);
        if (comptime trace.debug_kernel) trace.emit(.trap_exit, intid, 0, 1);
        // Preemption handled by check_preempt in assembly epilogue.
        return;
    }

    const ec_bits: u6 = @truncate(frame.esr >> 26);
    const ec: TrapClass = @enumFromInt(ec_bits);
    if (comptime trace.debug_kernel) trace.emit(.trap_enter, frame.pc(), @intFromEnum(ec), 1);

    switch (ec) {
        .simd_fp => switch (tryHandleFpuTrap()) {
            .handled => return,
            .oom => task.scheduler.exit(),
            .not_fpu => {},
        },
        else => {},
    }
    // TODO(syscall): Handle SVC from userspace.
    // TODO(vm): Handle user page faults.
    panicTrap(frame, ec.name());
}

/// Try to handle this trap as FPU access and return policy result.
/// ARM64: simd_fp (EC=0x07) means FPU/SIMD access when FPEN traps.
fn tryHandleFpuTrap() hal_fpu.TrapResult {
    const thread = task.scheduler.current() orelse return .not_fpu;
    return hal_fpu.handleTrap(thread, @truncate(cpu.currentId()));
}

/// Print minimal panic information and backtrace, then halt.
fn panicTrap(frame: *const TrapFrame, cause_name: []const u8) noreturn {
    _ = cpu.disableInterrupts();

    print("\n[panic] ");
    print(cause_name);
    print("\n\n");

    printField("pc", frame.pc());
    printField("cause", frame.cause());
    printField("addr", frame.faultAddr());

    backtrace.printBacktrace(frame.fp(), frame.pc());

    cpu.halt();
}

/// Print minimal panic information for IRQ, then halt.
fn panicIrq(frame: *const TrapFrame, intid: u32) noreturn {
    _ = cpu.disableInterrupts();

    print("\n[panic] unhandled IRQ ");
    print(&fmt.formatHex(intid));
    print("\n\n");

    printField("pc", frame.pc());

    backtrace.printBacktrace(frame.fp(), frame.pc());

    cpu.halt();
}

/// Print a field in "name   0x<value>" format.
fn printField(name: []const u8, value: usize) void {
    print(name);
    // Pad to 7 characters
    var padding: usize = 7 - @min(name.len, 7);
    while (padding > 0) : (padding -= 1) {
        print(" ");
    }
    print("0x");
    print(&fmt.formatHex(value));
    print("\n");
}

/// Initialize trap handling by installing the vector table.
pub fn init() void {
    const vbar = @intFromPtr(&trap_vectors);

    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );
    cpu.instructionBarrier();
}

test "validates TrapFrame size and layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 288), TrapFrame.FRAME_SIZE);
}

test "defines TrapClass names for known exceptions" {
    const std = @import("std");
    // Test specific known classes have meaningful names
    try std.testing.expect(TrapClass.brk_aarch64.name().len > 0);
    try std.testing.expect(TrapClass.svc_aarch64.name().len > 0);
    try std.testing.expect(TrapClass.data_abort_same.name().len > 0);
    try std.testing.expect(TrapClass.inst_abort_same.name().len > 0);
    try std.testing.expect(TrapClass.pc_align.name().len > 0);
    try std.testing.expect(TrapClass.sp_align.name().len > 0);
    try std.testing.expect(TrapClass.serror.name().len > 0);

    // Test unknown class returns fallback
    const unknown: TrapClass = @enumFromInt(0x3F); // Not a defined class
    try std.testing.expectEqualStrings("other exception", unknown.name());
}

test "returns correct values from TrapFrame.getReg" {
    const std = @import("std");
    var frame: TrapFrame = undefined;

    // Set up test values
    for (0..31) |i| {
        frame.regs[i] = @as(u64, i) + 100;
    }

    // Verify getReg returns correct values
    try std.testing.expectEqual(@as(u64, 100), frame.getReg(0));
    try std.testing.expectEqual(@as(u64, 101), frame.getReg(1));
    try std.testing.expectEqual(@as(u64, 130), frame.getReg(30));

    // Out of bounds returns 0
    try std.testing.expectEqual(@as(u64, 0), frame.getReg(31));
    try std.testing.expectEqual(@as(u64, 0), frame.getReg(100));
}
