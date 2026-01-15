//! RISC-V Trap Handling.
//!
//! RISC-V has three privilege levels: Machine (M), Supervisor (S), and User (U).
//! OpenSBI runs at M-mode and delegates most traps to S-mode where our kernel runs.
//! When a trap occurs, hardware saves state to CSRs and jumps to the address in stvec.
//!
//! Hardware-saved state:
//! - sepc: Exception program counter (return address)
//! - sstatus: Saved status (privilege level, interrupt enable)
//! - scause: Cause code (bit 63 = interrupt flag, lower bits = cause)
//! - stval: Trap value (fault address or faulting instruction)
//!
//! We use Vectored mode where interrupts jump to base + 4*cause, allowing fast dispatch
//! without reading scause. Exceptions all go to base+0.
//!
//! See RISC-V Privileged Specification, Chapter 12 (Supervisor-Level ISA).

const clock = @import("../../clock/clock.zig");
const console = @import("../../console/console.zig");
const trap = @import("../../trap/trap.zig");

const panic_msg = struct {
    const UNHANDLED = "TRAP: unhandled";
};

// Use printUnsafe in trap context: we can't safely acquire locks here
const print = console.printUnsafe;

/// Saved register context during trap. Layout must match assembly save/restore order.
/// RISC-V calling convention: a0-a7 arguments, s0-s11 callee-saved, ra return address.
pub const TrapContext = extern struct {
    regs: [31]u64, // x1-x31 (x0 is zero, regs[1] is modified SP)
    sp: u64, // Original stack pointer
    sepc: u64, // Exception PC (return address)
    sstatus: u64, // Status (privilege, interrupt enable)
    scause: u64, // Cause (bit 63: interrupt, lower: code)
    stval: u64, // Trap value (fault address or instruction)

    pub const FRAME_SIZE = @sizeOf(TrapContext);

    comptime {
        if (FRAME_SIZE != 288) @compileError("TrapContext size mismatch - update assembly!");
    }

    /// Get register value by index (x0-x31).
    /// Returns the original SP for x2, not the modified stack pointer in regs[1].
    /// Returns 0 for out-of-bounds indices.
    pub inline fn getReg(self: *const TrapContext, idx: usize) u64 {
        if (idx == 0) return 0; // x0 is always zero
        if (idx > 31) return 0; // out of bounds
        if (idx == 2) return self.sp; // x2/sp: return original, not modified
        return self.regs[idx - 1];
    }
};

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
/// Timer interrupt (cause 5) uses dedicated fast path timerEntry.
export fn trapVector() align(256) linksection(".trap") callconv(.naked) void {
    asm volatile (
    // Base + 0: Exceptions (all synchronous traps)
        \\ j trapEntry
        // Base + 4: Supervisor Software Interrupt (Cause 1)
        \\ j trapEntry
        // Base + 8: Reserved (Cause 2)
        \\ j trapEntry
        // Base + 12: Reserved (Cause 3)
        \\ j trapEntry
        // Base + 16: Reserved (Cause 4)
        \\ j trapEntry
        // Base + 20: Supervisor Timer Interrupt (Cause 5)
        \\ j timerEntry
        // Base + 24: Reserved (Cause 6)
        \\ j trapEntry
        // Base + 28: Reserved (Cause 7)
        \\ j trapEntry
        // Base + 32: Reserved (Cause 8)
        \\ j trapEntry
        // Base + 36: Supervisor External Interrupt (Cause 9)
        \\ j trapEntry
        // Fill up to 16 entries to be safe (up to Cause 15)
        \\ j trapEntry
        \\ j trapEntry
        \\ j trapEntry
        \\ j trapEntry
        \\ j trapEntry
        \\ j trapEntry
    );
}

/// Common trap handler entry point.
/// Stack frame: 288 bytes (x1-x31, sp, sepc, sstatus, scause, stval).
/// On trap entry, hardware clears sstatus.SIE (saved to SPIE), preventing nesting.
/// sret restores SIE from SPIE.
export fn trapEntry() linksection(".trap") callconv(.naked) noreturn {
    // Save all general-purpose registers except x0 (hardwired zero).
    // We use x5 (t0) as scratch after saving it.
    asm volatile (
    // Allocate stack frame
        \\addi sp, sp, -288

        // Save x1-x31 (x0 is hardwired zero, not saved)
        \\sd x1, 0(sp)
        \\sd x2, 8(sp)
        \\sd x3, 16(sp)
        \\sd x4, 24(sp)
        \\sd x5, 32(sp)
        \\sd x6, 40(sp)
        \\sd x7, 48(sp)
        \\sd x8, 56(sp)
        \\sd x9, 64(sp)
        \\sd x10, 72(sp)
        \\sd x11, 80(sp)
        \\sd x12, 88(sp)
        \\sd x13, 96(sp)
        \\sd x14, 104(sp)
        \\sd x15, 112(sp)
        \\sd x16, 120(sp)
        \\sd x17, 128(sp)
        \\sd x18, 136(sp)
        \\sd x19, 144(sp)
        \\sd x20, 152(sp)
        \\sd x21, 160(sp)
        \\sd x22, 168(sp)
        \\sd x23, 176(sp)
        \\sd x24, 184(sp)
        \\sd x25, 192(sp)
        \\sd x26, 200(sp)
        \\sd x27, 208(sp)
        \\sd x28, 216(sp)
        \\sd x29, 224(sp)
        \\sd x30, 232(sp)
        \\sd x31, 240(sp)

        // Calculate and save original SP (SP before addi -288)
        \\addi t0, sp, 288
        \\sd t0, 248(sp)

        // Save sepc (return address)
        \\csrr t0, sepc
        \\sd t0, 256(sp)

        // Save sstatus (saved status)
        \\csrr t0, sstatus
        \\sd t0, 264(sp)

        // Save scause
        \\csrr t0, scause
        \\sd t0, 272(sp)

        // Save stval
        \\csrr t0, stval
        \\sd t0, 280(sp)

        // Call Zig trap handler with pointer to context
        \\mv a0, sp
        \\call handleTrap

        // Restore sepc and sstatus (may have been modified by handler)
        \\ld t0, 256(sp)
        \\csrw sepc, t0
        \\ld t0, 264(sp)
        \\csrw sstatus, t0

        // Restore general-purpose registers
        \\ld x1, 0(sp)
        // Skip x2 (sp) - restore at end
        \\ld x3, 16(sp)
        \\ld x4, 24(sp)
        \\ld x5, 32(sp)
        \\ld x6, 40(sp)
        \\ld x7, 48(sp)
        \\ld x8, 56(sp)
        \\ld x9, 64(sp)
        \\ld x10, 72(sp)
        \\ld x11, 80(sp)
        \\ld x12, 88(sp)
        \\ld x13, 96(sp)
        \\ld x14, 104(sp)
        \\ld x15, 112(sp)
        \\ld x16, 120(sp)
        \\ld x17, 128(sp)
        \\ld x18, 136(sp)
        \\ld x19, 144(sp)
        \\ld x20, 152(sp)
        \\ld x21, 160(sp)
        \\ld x22, 168(sp)
        \\ld x23, 176(sp)
        \\ld x24, 184(sp)
        \\ld x25, 192(sp)
        \\ld x26, 200(sp)
        \\ld x27, 208(sp)
        \\ld x28, 216(sp)
        \\ld x29, 224(sp)
        \\ld x30, 232(sp)
        \\ld x31, 240(sp)

        // Restore SP and return from trap
        \\addi sp, sp, 288
        \\sret
    );
}

/// Timer interrupt fast path - saves only caller-saved registers.
/// RISC-V calling convention guarantees s0-s11 are callee-saved.
/// We only save ra, t0-t6, a0-a7 (16 regs) plus sepc/sstatus for return.
/// Frame: 144 bytes = 16 regs + sepc + sstatus (16-byte aligned).
export fn timerEntry() linksection(".trap") callconv(.naked) noreturn {
    asm volatile (
    // Allocate frame for caller-saved registers only
        \\addi sp, sp, -144

        // Save ra (x1)
        \\sd ra, 0(sp)

        // Save t0-t2 (x5-x7)
        \\sd t0, 8(sp)
        \\sd t1, 16(sp)
        \\sd t2, 24(sp)

        // Save a0-a7 (x10-x17)
        \\sd a0, 32(sp)
        \\sd a1, 40(sp)
        \\sd a2, 48(sp)
        \\sd a3, 56(sp)
        \\sd a4, 64(sp)
        \\sd a5, 72(sp)
        \\sd a6, 80(sp)
        \\sd a7, 88(sp)

        // Save t3-t6 (x28-x31)
        \\sd t3, 96(sp)
        \\sd t4, 104(sp)
        \\sd t5, 112(sp)
        \\sd t6, 120(sp)

        // Save sepc and sstatus for sret
        \\csrr t0, sepc
        \\sd t0, 128(sp)
        \\csrr t0, sstatus
        \\sd t0, 136(sp)

        // Call timer handler directly
        \\call handleTimerIrq

        // Restore sepc and sstatus
        \\ld t0, 128(sp)
        \\csrw sepc, t0
        \\ld t0, 136(sp)
        \\csrw sstatus, t0

        // Restore t3-t6
        \\ld t3, 96(sp)
        \\ld t4, 104(sp)
        \\ld t5, 112(sp)
        \\ld t6, 120(sp)

        // Restore a0-a7
        \\ld a0, 32(sp)
        \\ld a1, 40(sp)
        \\ld a2, 48(sp)
        \\ld a3, 56(sp)
        \\ld a4, 64(sp)
        \\ld a5, 72(sp)
        \\ld a6, 80(sp)
        \\ld a7, 88(sp)

        // Restore t0-t2
        \\ld t0, 8(sp)
        \\ld t1, 16(sp)
        \\ld t2, 24(sp)

        // Restore ra
        \\ld ra, 0(sp)

        // Deallocate and return
        \\addi sp, sp, 144
        \\sret
    );
}

/// Main trap handler - examines scause and dispatches or panics.
export fn handleTrap(ctx: *TrapContext) void {
    const cause = @as(TrapCause, @enumFromInt(ctx.scause));
    dumpTrap(ctx, cause);
    @panic(panic_msg.UNHANDLED);
}

/// Timer interrupt handler called from timerEntry assembly.
export fn handleTimerIrq() void {
    clock.handleTimerIrq();
}

fn dumpTrap(ctx: *const TrapContext, cause: TrapCause) void {
    // Print trap header
    print("\nTrap: ");
    print(cause.name());
    print(" \n");

    // Print key registers inline
    printKeyRegister("sepc", ctx.sepc);
    print(" ");
    printKeyRegister("sp", ctx.sp);
    print(" ");
    printKeyRegister("scause", ctx.scause);
    print(" ");
    printKeyRegister("stval", ctx.stval);
    print("\n");

    // Dump all general-purpose registers (x1-x31)
    const reg_names = [_][]const u8{
        "ra", "sp",  "gp",  "tp", "t0", "t1", "t2", "s0",
        "s1", "a0",  "a1",  "a2", "a3", "a4", "a5", "a6",
        "a7", "s2",  "s3",  "s4", "s5", "s6", "s7", "s8",
        "s9", "s10", "s11", "t3", "t4", "t5", "t6",
    };
    for (reg_names, 0..) |name, i| {
        print(&trap.fmt.formatRegName(name));
        print("0x");
        print(&trap.fmt.formatHex(ctx.regs[i]));
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

/// Initialize trap handling by installing stvec (Vectored mode).
/// Called twice: first at physical addresses (with identity mapping),
/// then at virtual addresses after boot.zig switches to higher-half.
pub fn init() void {
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

/// Trigger breakpoint exception for testing (EBREAK -> scause=3).
pub fn testTriggerBreakpoint() void {
    asm volatile ("ebreak");
}

/// Trigger illegal instruction exception (all-zeros is illegal on RISC-V).
pub fn testTriggerIllegalInstruction() void {
    asm volatile (".word 0x00000000");
}

/// Wait for interrupt (single wait, returns after interrupt handled).
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}

/// Halt CPU (loop forever, interrupts still enabled).
pub inline fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

/// Disable all interrupts. Returns previous interrupt state.
pub inline fn disableInterrupts() bool {
    var sstatus: u64 = undefined;
    asm volatile ("csrr %[sstatus], sstatus"
        : [sstatus] "=r" (sstatus),
    );
    asm volatile ("csrci sstatus, 0x2");
    return (sstatus & 0x2) != 0; // Returns true if SIE was enabled
}

/// Enable interrupts.
pub inline fn enableInterrupts() void {
    asm volatile ("csrsi sstatus, 0x2");
}

test "TrapContext size and layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 288), TrapContext.FRAME_SIZE);
}

test "TrapCause.isInterrupt detects interrupt bit" {
    const std = @import("std");
    try std.testing.expect(TrapCause.isInterrupt(0x8000000000000005));
    try std.testing.expect(!TrapCause.isInterrupt(0x0000000000000005));
    try std.testing.expectEqual(@as(u64, 5), TrapCause.code(0x8000000000000005));
    try std.testing.expectEqual(@as(u64, 5), TrapCause.code(0x0000000000000005));
}

test "TrapCause names are defined for known exceptions" {
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

test "TrapContext.getReg handles special cases" {
    const std = @import("std");
    var ctx: TrapContext = undefined;

    // Set up test values
    for (0..31) |i| {
        ctx.regs[i] = @as(u64, i) + 100;
    }
    ctx.sp = 0xDEADBEEF; // Original SP

    // x0 always returns 0
    try std.testing.expectEqual(@as(u64, 0), ctx.getReg(0));

    // x1 (ra) comes from regs[0]
    try std.testing.expectEqual(@as(u64, 100), ctx.getReg(1));

    // x2 (sp) returns original SP, not regs[1]
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), ctx.getReg(2));

    // x3+ come from regs array
    try std.testing.expectEqual(@as(u64, 102), ctx.getReg(3));
    try std.testing.expectEqual(@as(u64, 130), ctx.getReg(31));
}
