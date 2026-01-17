//! ARM64 Trap Handling.
//!
//! ARM64 uses a 16-entry exception vector table organized as 4 exception types
//! (Synchronous, IRQ, FIQ, SError) × 4 sources (Current EL with SP0/SPx, Lower EL
//! AArch64/AArch32). Each entry is 128 bytes and the table must be 2KB aligned.
//!
//! Hardware saves ELR_EL1 (return address), SPSR_EL1 (status), and masks interrupts
//! before jumping to the vector. We save remaining registers in trap_entry.zig.
//! Kernel traps use SP_EL1 directly; user traps read SP_EL0 to capture the user stack.
//!
//! See ARM Architecture Reference Manual, D1.4 (Exceptions).
//!
//! TODO(syscall): Fast path dispatch - skip slow path if no pending work flags.
//! TODO(smp): Per-CPU trap state tracking reentry depth.
//! TODO(fpu): Lazy FPU for userspace - trap on EC=0x07 (simd_fp), restore state,
//!            set CPACR_EL1.FPEN=0b11, track fpu_owner per-CPU.

const clock = @import("../../clock/clock.zig");
const console = @import("../../console/console.zig");
const gic = @import("gic.zig");
const trap = @import("../../trap/trap.zig");
const trap_entry = @import("trap_entry.zig");
const trap_frame = @import("trap_frame.zig");

const panic_msg = struct {
    const UNHANDLED = "TRAP: unhandled";
    const UNHANDLED_IRQ = "TRAP: unhandled interrupt";
};

// Use printUnsafe in trap context: we can't safely acquire locks here
const print = console.printUnsafe;

/// Saved register context during trap. Layout must match assembly save/restore order.
const TrapFrame = trap_frame.TrapFrame;

/// Exception class from ESR_EL1[31:26].
/// See ARM Architecture Reference Manual, ESR_EL1.EC field encoding.
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

    /// Get human-readable name for this exception class.
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

/// VBAR_EL1 requires 2KB alignment (bits 10:0 must be 0).
const VBAR_ALIGNMENT = 2048;

/// Trap vector table - must be 2KB aligned per ARM spec.
/// 16 entries × 128 bytes each. Kernel and user traps use separate entry points.
/// Static assembly - no runtime patching needed, linker resolves offsets.
export fn trap_vectors() align(VBAR_ALIGNMENT) linksection(".vectors") callconv(.naked) void {
    // 16 vector entries, each 128 bytes (32 instructions).
    // Entry order within each group: Synchronous, IRQ, FIQ, SError
    asm volatile (
    // Current EL with SP_EL0 (0x000 - 0x1FF) - shouldn't happen, we use SP_ELx
        \\ b kernelTrapEntry  // 0x000: Synchronous
        \\ .balign 128
        \\ b kernelIrqEntry   // 0x080: IRQ
        \\ .balign 128
        \\ b kernelTrapEntry  // 0x100: FIQ
        \\ .balign 128
        \\ b kernelTrapEntry  // 0x180: SError
        \\ .balign 128
        // Current EL with SP_ELx (0x200 - 0x3FF) - kernel mode
        \\ b kernelTrapEntry  // 0x200: Synchronous
        \\ .balign 128
        \\ b kernelIrqEntry   // 0x280: IRQ
        \\ .balign 128
        \\ b kernelTrapEntry  // 0x300: FIQ
        \\ .balign 128
        \\ b kernelTrapEntry  // 0x380: SError
        \\ .balign 128
        // Lower EL using AArch64 (0x400 - 0x5FF) - userspace
        \\ b userTrapEntry    // 0x400: Synchronous
        \\ .balign 128
        \\ b userTrapEntry    // 0x480: IRQ (unified with traps)
        \\ .balign 128
        \\ b userTrapEntry    // 0x500: FIQ
        \\ .balign 128
        \\ b userTrapEntry    // 0x580: SError
        \\ .balign 128
        // Lower EL using AArch32 (0x600 - 0x7FF) - not supported
        \\ b userTrapEntry    // 0x600: Synchronous
        \\ .balign 128
        \\ b userTrapEntry    // 0x680: IRQ
        \\ .balign 128
        \\ b userTrapEntry    // 0x700: FIQ
        \\ .balign 128
        \\ b userTrapEntry    // 0x780: SError
        \\ .balign 128
    );
}

// Entry points generated from a single template (see trap_entry.zig).

/// Kernel trap entry. Full save; kernel faults are bugs.
export fn kernelTrapEntry() callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleKernelTrap",
            .pass_frame = true,
        }));
}

/// Kernel IRQ entry. Fast path with caller-saved registers only.
/// AAPCS64 guarantees x19-x28 are callee-saved, so handler preserves them.
export fn kernelIrqEntry() callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = false,
            .handler = "handleKernelIrq",
            .pass_frame = false,
        }));
}

/// User trap entry. Full save for all user-mode traps and interrupts.
/// Single entry point; handler checks for pending IRQs.
/// Saves user SP from SP_EL0; kernel already uses SP_EL1 at EL1.
/// TODO(scheduler): Set SP_EL1 to per-thread kernel stack on context switch.
export fn userTrapEntry() callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleUserTrap",
            .pass_frame = true,
            .save_sp_el0 = true,
        }));
}

/// Spurious interrupt ID returned by GIC when no interrupt is pending.
const SPURIOUS_INTID: u32 = 1023;

const TIMER_PPI = gic.TIMER_PPI;

/// Kernel IRQ handler. Acknowledge, dispatch, end-of-interrupt.
export fn handleKernelIrq() void {
    const intid = gic.acknowledge();
    if (intid == SPURIOUS_INTID) return;

    switch (intid) {
        TIMER_PPI => clock.handleTimerIrq(),
        else => @panic(panic_msg.UNHANDLED_IRQ),
    }

    gic.endOfInterrupt(intid);
}

/// Kernel trap handler. Kernel faults are bugs, always panic.
export fn handleKernelTrap(frame: *TrapFrame) void {
    const ec = @as(TrapClass, @enumFromInt(@as(u6, @truncate(frame.esr >> 26))));
    dumpTrap(frame, ec);
    // TODO(syscall): Handle SVC exceptions.
    // TODO(vm): Handle page faults.
    @panic(panic_msg.UNHANDLED);
}

/// User trap handler. Unified entry for all user-mode traps and interrupts.
/// TODO(process): Terminate process on fault instead of panic.
/// TODO(signals): Deliver signal to userspace exception handler.
export fn handleUserTrap(frame: *TrapFrame) void {
    // If a pending IRQ is latched, handle it; otherwise treat as sync exception.
    const intid = gic.acknowledge();
    if (intid != SPURIOUS_INTID) {
        switch (intid) {
            TIMER_PPI => clock.handleTimerIrq(),
            else => @panic(panic_msg.UNHANDLED_IRQ),
        }
        gic.endOfInterrupt(intid);
        // TODO(scheduler): Check need_resched flag and context switch if needed.
        return;
    }

    const ec = @as(TrapClass, @enumFromInt(@as(u6, @truncate(frame.esr >> 26))));
    print("\nUser trap: ");
    print(ec.name());
    print("\n");
    dumpTrap(frame, ec);
    // TODO(syscall): Handle SVC from userspace.
    // TODO(vm): Handle user page faults.
    @panic(panic_msg.UNHANDLED);
}

/// Print trap information and register dump for debugging.
fn dumpTrap(frame: *const TrapFrame, ec: TrapClass) void {
    print("\nTrap: ");
    print(ec.name());
    print(" \n");

    printKeyRegister("elr", frame.elr);
    print(" ");
    printKeyRegister("sp", frame.sp_saved);
    print(" ");
    printKeyRegister("esr", frame.esr);
    print(" ");
    printKeyRegister("far", frame.far);
    print("\n");

    const reg_names = [_][]const u8{
        "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
        "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
        "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
        "x24", "x25", "x26", "x27", "x28", "x29", "x30",
    };
    for (reg_names, 0..) |reg_name, i| {
        print(&trap.fmt.formatRegName(reg_name));
        print("0x");
        print(&trap.fmt.formatHex(frame.regs[i]));
        if ((i + 1) % 4 == 0) {
            print("\n");
        } else {
            print(" ");
        }
    }
}

fn printKeyRegister(name: []const u8, value: u64) void {
    print(&trap.fmt.formatRegName(name));
    print("0x");
    print(&trap.fmt.formatHex(value));
}

/// Initialize trap handling by installing the vector table.
pub fn init() void {
    const vbar = @intFromPtr(&trap_vectors);

    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );
    asm volatile ("isb");
}

/// Trigger a synchronous trap for testing (BRK instruction).
/// BRK #0 generates EC=0x3C (brk_aarch64) in ESR_EL1.
pub fn testTriggerBreakpoint() void {
    asm volatile ("brk #0");
}

/// Trigger illegal instruction trap for testing.
/// Uses UDF instruction which is guaranteed undefined on all ARM implementations.
pub fn testTriggerIllegalInstruction() void {
    asm volatile (".word 0x00000000"); // UDF #0
}

/// Wait for interrupt (single wait, returns after interrupt handled).
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}

/// Halt CPU (loop forever, interrupts still enabled).
pub inline fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

/// Disable IRQ and FIQ. Returns true if IRQs were previously enabled.
/// Does not mask Debug or SError - those indicate serious conditions.
pub inline fn disableInterrupts() bool {
    var daif: u64 = undefined;
    asm volatile ("mrs %[daif], daif"
        : [daif] "=r" (daif),
    );
    asm volatile ("msr daifset, #3"); // Mask I and F only (bits 1:0)
    return (daif & 0x80) == 0; // Bit 7 = I flag, clear = enabled
}

/// Enable IRQ and FIQ.
pub inline fn enableInterrupts() void {
    asm volatile ("msr daifclr, #3"); // Unmask I and F only
}

test "TrapFrame size and layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 288), TrapFrame.FRAME_SIZE);
}

test "TrapClass names are defined for known exceptions" {
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

test "TrapFrame.getReg returns correct values" {
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
