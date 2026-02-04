//! RISC-V Trap Handling.
//!
//! RISC-V uses a single stvec register pointing to the trap vector. We use Vectored
//! mode where interrupts jump to base + 4*cause for fast dispatch without reading
//! scause; exceptions all go to base+0.
//!
//! Hardware saves state to CSRs (sepc, sstatus, scause, stval) and jumps to stvec.
//! OpenSBI runs at M-mode and delegates most traps to S-mode where our kernel runs.
//!
//! User traps swap SP with sscratch to enter on the kernel stack. The sscratch CSR
//! holds the kernel SP when in user mode, allowing atomic stack switch on trap entry.
//!
//! See RISC-V Privileged Specification, Chapter 12 (Supervisor-Level ISA).
//!
//! TODO(syscall): Fast path dispatch - skip slow path if no pending work flags.
//! TODO(smp): Per-CPU trap state tracking reentry depth.

const backtrace = @import("../../trap/backtrace.zig");
const clock = @import("../../clock/clock.zig");
const console = @import("../../console/console.zig");
const fpu = @import("fpu.zig");
const hal_fpu = @import("../../hal/fpu.zig");
const task = @import("../../task/task.zig");
const trace = @import("../../debug/trace.zig");
const cpu = @import("cpu.zig");
const fmt = @import("../../trap/fmt.zig");
const trap_entry = @import("trap_entry.zig");
const trap_frame = @import("trap_frame.zig");

// Use printUnsafe in trap context: we can't safely acquire locks here
const print = console.printUnsafe;

/// Saved register context during trap. Layout must match assembly save/restore order.
const TrapFrame = trap_frame.TrapFrame;

/// Trap cause from scause register. Bit 63: interrupt (1) vs exception (0).
/// See RISC-V Privileged Specification, Table 32.
pub const TrapCause = enum(u64) {
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
    reserved_10 = 10,
    ecall_from_m = 11,
    instruction_page_fault = 12,
    load_page_fault = 13,
    reserved_14 = 14,
    store_page_fault = 15,
    reserved_16 = 16,
    reserved_17 = 17,
    reserved_18 = 18,
    reserved_19 = 19,
    instruction_guest_page_fault = 20,
    load_guest_page_fault = 21,
    virtual_instruction = 22,
    store_guest_page_fault = 23,
    supervisor_software_interrupt = 0x8000000000000001,
    supervisor_timer_interrupt = 0x8000000000000005,
    supervisor_external_interrupt = 0x8000000000000009,

    _,

    /// Check if scause indicates an interrupt (bit 63 set) vs exception.
    pub inline fn isInterrupt(cause: u64) bool {
        return (cause >> 63) == 1;
    }

    /// Extract the cause code (lower 63 bits) from scause.
    pub inline fn code(cause: u64) u64 {
        return cause & ~(@as(u64, 1) << 63);
    }

    /// Get human-readable name for this trap cause.
    pub fn name(self: TrapCause) []const u8 {
        return switch (self) {
            .instruction_misaligned => "instruction address misaligned",
            .instruction_access_fault => "instruction access fault",
            .illegal_instruction => "illegal instruction",
            .breakpoint => "breakpoint",
            .load_misaligned => "load address misaligned",
            .load_access_fault => "load access fault",
            .store_misaligned => "store address misaligned",
            .store_access_fault => "store access fault",
            .ecall_from_u => "environment call from user mode",
            .ecall_from_s => "environment call from supervisor mode",
            .reserved_10 => "reserved",
            .ecall_from_m => "environment call from machine mode",
            .instruction_page_fault => "instruction page fault",
            .load_page_fault => "load page fault",
            .reserved_14 => "reserved",
            .store_page_fault => "store page fault",
            .reserved_16 => "reserved",
            .reserved_17 => "reserved",
            .reserved_18 => "reserved",
            .reserved_19 => "reserved",
            .instruction_guest_page_fault => "instruction guest page fault",
            .load_guest_page_fault => "load guest page fault",
            .virtual_instruction => "virtual instruction",
            .store_guest_page_fault => "store guest page fault",
            .supervisor_software_interrupt => "supervisor software interrupt",
            .supervisor_timer_interrupt => "supervisor timer interrupt",
            .supervisor_external_interrupt => "supervisor external interrupt",
            else => "unknown trap",
        };
    }
};

/// Trap vector table. Aligned to 256 bytes as per spec.
/// Vectored mode: interrupts jump to base + 4*cause, exceptions to base.
/// All entries dispatch based on sstatus.SPP (user vs kernel origin).
export fn trapVector() align(256) linksection(".trap") callconv(.naked) void {
    asm volatile (
    // Base + 0: Exceptions (synchronous)
        \\ j trapDispatch
        // Base + 4: Supervisor Software Interrupt (Cause 1)
        \\ j interruptDispatch
        // Base + 8-16: Reserved (Cause 2-4)
        \\ j trapDispatch
        \\ j trapDispatch
        \\ j trapDispatch
        // Base + 20: Supervisor Timer Interrupt (Cause 5)
        \\ j interruptDispatch
        // Base + 24-32: Reserved (Cause 6-8)
        \\ j trapDispatch
        \\ j trapDispatch
        \\ j trapDispatch
        // Base + 36: Supervisor External Interrupt (Cause 9)
        \\ j interruptDispatch
        // Fill to 16 entries (Cause 10-15)
        \\ j trapDispatch
        \\ j trapDispatch
        \\ j trapDispatch
        \\ j trapDispatch
        \\ j trapDispatch
        \\ j trapDispatch
    );
}

/// Trap dispatch - routes to kernel or user handler based on sstatus.SPP.
/// SPP bit (bit 8): 0 = from U-mode, 1 = from S-mode.
export fn trapDispatch() linksection(".trap") callconv(.naked) noreturn {
    asm volatile (
        \\ csrr t0, sstatus
        \\ andi t0, t0, 0x100
        \\ bnez t0, kernelTrapEntry
        \\ j userTrapEntry
    );
}

/// Interrupt dispatch - kernel uses fast path, user needs full save.
export fn interruptDispatch() linksection(".trap") callconv(.naked) noreturn {
    asm volatile (
        \\ csrr t0, sstatus
        \\ andi t0, t0, 0x100
        \\ bnez t0, kernelInterruptEntry
        \\ j userTrapEntry
    );
}

// Entry points generated from a single template.
// See trap_entry.zig for the comptime generator.

/// Kernel trap entry - full save for debugging. Kernel faults are bugs.
export fn kernelTrapEntry() linksection(".trap") callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleKernelTrap",
            .pass_frame = true,
        }));
}

/// Kernel interrupt entry - full save to allow safe preemption.
/// Handles timer, software, and external interrupts from kernel context.
export fn kernelInterruptEntry() linksection(".trap") callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleKernelInterrupt",
            .pass_frame = false,
            .check_preempt = true,
        }));
}

/// User trap entry. Full save for all user-mode traps and interrupts.
/// Single entry point; handler dispatches by scause.
/// Swaps SP with sscratch to enter on kernel stack; saves user SP.
export fn userTrapEntry() linksection(".trap") callconv(.naked) noreturn {
    asm volatile (trap_entry.genEntryAsm(.{
            .full_save = true,
            .handler = "handleUserTrap",
            .pass_frame = true,
            .use_sscratch = true,
            .check_preempt = true,
        }));
}

/// Kernel trap handler. Most kernel faults are bugs, but FPU traps are expected.
export fn handleKernelTrap(frame: *TrapFrame) callconv(.c) void {
    const cause = @as(TrapCause, @enumFromInt(frame.scause));
    if (comptime trace.debug_kernel) trace.emit(.trap_enter, frame.pc(), @intFromEnum(cause), 0);

    switch (cause) {
        .illegal_instruction => if (tryHandleFpuTrap()) return,
        else => {},
    }
    // TODO(syscall): Handle ECALL from S-mode.
    // TODO(vm): Handle kernel page faults.
    panicTrap(frame, cause.name());
}

/// Kernel interrupt handler. Dispatches timer, software, and external interrupts.
/// Note: No frame available (fast path) - only prints scause on panic.
export fn handleKernelInterrupt() void {
    const scause = asm volatile ("csrr %[ret], scause"
        : [ret] "=r" (-> u64),
    );
    const code = TrapCause.code(scause);
    if (comptime trace.debug_kernel) trace.emit(.trap_enter, scause, code, 0);

    switch (code) {
        5 => clock.handleTimerIrq(), // Supervisor timer
        1 => handleSoftwareInterrupt(),
        9 => {}, // TODO(plic): Supervisor external interrupt
        else => panicKernelInterrupt(scause),
    }
    if (comptime trace.debug_kernel) trace.emit(.trap_exit, scause, code, 0);
    // Preemption handled by check_preempt in assembly epilogue.
}

/// Print minimal panic for unhandled kernel interrupt (no frame available).
fn panicKernelInterrupt(scause: u64) noreturn {
    _ = cpu.disableInterrupts();

    print("\n[panic] unhandled kernel interrupt\n\n");
    printField("scause", scause);

    cpu.halt();
}

/// Clear SSIP to acknowledge software interrupt; without this it re-triggers.
fn handleSoftwareInterrupt() void {
    asm volatile ("csrc sip, %[mask]"
        :
        : [mask] "r" (@as(u64, 1 << 1)),
    );
    // TODO(ipi): Actual IPI handling
}

/// User trap handler. Unified entry for all user-mode traps and interrupts.
/// TODO(process): Terminate process on fault instead of panic.
/// TODO(signals): Deliver signal to userspace exception handler.
export fn handleUserTrap(frame: *TrapFrame) void {
    const cause = @as(TrapCause, @enumFromInt(frame.scause));

    if (TrapCause.isInterrupt(frame.scause)) {
        const code = TrapCause.code(frame.scause);
        if (comptime trace.debug_kernel) trace.emit(.trap_enter, frame.scause, code, 1);
        switch (code) {
            5 => clock.handleTimerIrq(), // Supervisor timer
            1 => handleSoftwareInterrupt(),
            9 => {}, // TODO(plic): Supervisor external interrupt
            else => panicTrap(frame, cause.name()),
        }
        if (comptime trace.debug_kernel) trace.emit(.trap_exit, frame.scause, code, 1);
        // Preemption handled by check_preempt in assembly epilogue.
        return;
    }

    if (comptime trace.debug_kernel) trace.emit(.trap_enter, frame.pc(), @intFromEnum(cause), 1);

    switch (cause) {
        .illegal_instruction => if (tryHandleFpuTrap()) return,
        else => {},
    }
    // TODO(syscall): Handle ECALL from U-mode.
    // TODO(vm): Handle user page faults.
    panicTrap(frame, cause.name());
}

/// Try to handle as lazy FPU trap. Returns true if handled.
/// Heuristic: illegal_instruction with sstatus.FS=Off is assumed to be FPU access.
/// This may incorrectly handle non-FPU illegal instructions when FPU is disabled,
/// but in practice kernel code doesn't execute unknown instructions.
fn tryHandleFpuTrap() bool {
    if (fpu.isEnabled()) return false;
    const thread = task.scheduler.current() orelse return false;
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

/// Initialize trap handling by installing stvec (Vectored mode).
/// Stores kernel SP in sscratch so user traps land on kernel stack.
/// Called twice: first at physical addresses (with identity mapping),
/// then at virtual addresses after boot.zig switches to higher-half.
/// See RISC-V Privileged Specification, 4.1.4 (Supervisor Scratch Register).
pub fn init() void {
    // Store kernel SP in sscratch for user trap entry.
    // User traps swap SP with sscratch to get kernel stack.
    const kernel_sp = asm volatile ("mv %[ret], sp"
        : [ret] "=r" (-> usize),
    );
    asm volatile ("csrw sscratch, %[sp]"
        :
        : [sp] "r" (kernel_sp),
    );

    // stvec format: [63:2] address, [1:0] mode (00=Direct, 01=Vectored)
    // Vectored mode: Exceptions -> Base, Interrupts -> Base + 4*Cause
    // Alignment guaranteed by align(256) on trapVector declaration.
    //
    // Use inline assembly to get the PC-relative address of trapVector.
    // This ensures we get the correct address whether running at physical
    // or virtual addresses, since PC-relative addressing works in either case.
    const stvec_val = asm volatile (
        \\ la %[ret], trapVector
        : [ret] "=r" (-> usize),
    ) | 1;

    asm volatile ("csrw stvec, %[stvec]"
        :
        : [stvec] "r" (stvec_val),
    );
    asm volatile ("fence.i"); // Ensure icache sees stvec code
}

test "validates TrapFrame size and layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 288), TrapFrame.FRAME_SIZE);
}

test "detects interrupt bit in TrapCause.isInterrupt" {
    const std = @import("std");
    try std.testing.expect(TrapCause.isInterrupt(0x8000000000000005));
    try std.testing.expect(!TrapCause.isInterrupt(0x0000000000000005));
    try std.testing.expectEqual(@as(u64, 5), TrapCause.code(0x8000000000000005));
    try std.testing.expectEqual(@as(u64, 5), TrapCause.code(0x0000000000000005));
}

test "defines TrapCause names for known exceptions" {
    const std = @import("std");
    // Test specific known causes have meaningful names
    try std.testing.expect(TrapCause.breakpoint.name().len > 0);
    try std.testing.expect(TrapCause.ecall_from_u.name().len > 0);
    try std.testing.expect(TrapCause.load_page_fault.name().len > 0);
    try std.testing.expect(TrapCause.store_page_fault.name().len > 0);
    try std.testing.expect(TrapCause.illegal_instruction.name().len > 0);
    try std.testing.expect(TrapCause.supervisor_timer_interrupt.name().len > 0);

    // Test unknown cause returns fallback
    const unknown: TrapCause = @enumFromInt(0x1234); // Not a defined cause
    try std.testing.expectEqualStrings("unknown trap", unknown.name());
}

test "handles special cases in TrapFrame.getReg" {
    const std = @import("std");
    var frame: TrapFrame = undefined;

    // Set up test values
    for (0..31) |i| {
        frame.regs[i] = @as(u64, i) + 100;
    }
    frame.sp_saved = 0xDEADBEEF; // Original SP

    // x0 always returns 0
    try std.testing.expectEqual(@as(u64, 0), frame.getReg(0));

    // x1 (ra) comes from regs[0]
    try std.testing.expectEqual(@as(u64, 100), frame.getReg(1));

    // x2 (sp) returns original SP, not regs[1]
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), frame.getReg(2));

    // x3+ come from regs array
    try std.testing.expectEqual(@as(u64, 102), frame.getReg(3));
    try std.testing.expectEqual(@as(u64, 130), frame.getReg(31));
}
