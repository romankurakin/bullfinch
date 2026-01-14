//! ARM64 Trap Handling.
//!
//! When the CPU encounters an exceptional condition (interrupt, fault, syscall), it
//! transfers control to a handler via the exception vector table. ARM64 calls these
//! "exceptions" but we use "trap" to match RISC-V and general OS terminology.
//!
//! The vector table has 16 entries organized as 4 exception types × 4 sources:
//! - Types: Synchronous (faults, syscalls), IRQ, FIQ, SError
//! - Sources: Current EL with SP0, Current EL with SPx, Lower EL AArch64, Lower EL AArch32
//!
//! Each entry is 128 bytes (32 instructions), and the table must be 2KB aligned.
//! Hardware automatically saves return address to ELR_EL1, status to SPSR_EL1, and
//! masks interrupts. We save remaining registers manually in the trap entry code.
//!
//! See ARM Architecture Reference Manual, Chapter D1 (The AArch64 Exception Model).

const clock = @import("../../clock/clock.zig");
const console = @import("../../console/console.zig");
const gic = @import("gic.zig");
const trap = @import("../../trap/trap.zig");

const panic_msg = struct {
    const UNHANDLED = "TRAP: unhandled";
    const UNHANDLED_IRQ = "TRAP: unhandled interrupt";
};

// Use printUnsafe in trap context: we can't safely acquire locks here
const print = console.printUnsafe;

/// Saved register context during trap. Layout must match assembly save/restore order.
/// ARM calling convention: x0-x7 arguments, x19-x28 callee-saved, x29 frame pointer, x30 link register.
pub const TrapContext = extern struct {
    regs: [31]u64, // x0-x30
    sp: u64, // Stack pointer at exception
    elr: u64, // Exception link register (return address)
    spsr: u64, // Saved program status register
    esr: u64, // Exception syndrome register (cause)
    far: u64, // Fault address register

    pub const FRAME_SIZE = @sizeOf(TrapContext);

    comptime {
        if (FRAME_SIZE != 288) @compileError("TrapContext size mismatch - update assembly!");
    }

    /// Get general-purpose register value by index (x0-x30). Returns 0 for invalid index.
    pub inline fn getReg(self: *const TrapContext, idx: usize) u64 {
        if (idx >= 31) return 0;
        return self.regs[idx];
    }
};

/// Exception class from ESR_EL1[31:26].
/// See ARM Architecture Reference Manual, Table D1-6.
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
/// 16 entries × 128 bytes each. IRQ entries branch to irqEntry, others to trapEntry.
/// Static assembly - no runtime patching needed, linker resolves offsets.
export fn trap_vectors() align(VBAR_ALIGNMENT) linksection(".vectors") callconv(.naked) void {
    // 16 vector entries, each 128 bytes (32 instructions).
    // Entry order within each group: Synchronous, IRQ, FIQ, SError
    asm volatile (
    // Current EL with SP_EL0 (0x000 - 0x1FF) - shouldn't happen, we use SP_ELx
        \\ b trapEntry      // 0x000: Synchronous
        \\ .balign 128
        \\ b irqEntry       // 0x080: IRQ
        \\ .balign 128
        \\ b trapEntry      // 0x100: FIQ
        \\ .balign 128
        \\ b trapEntry      // 0x180: SError
        \\ .balign 128
        // Current EL with SP_ELx (0x200 - 0x3FF) - main kernel mode
        \\ b trapEntry      // 0x200: Synchronous
        \\ .balign 128
        \\ b irqEntry       // 0x280: IRQ
        \\ .balign 128
        \\ b trapEntry      // 0x300: FIQ
        \\ .balign 128
        \\ b trapEntry      // 0x380: SError
        \\ .balign 128
        // Lower EL using AArch64 (0x400 - 0x5FF) - userspace
        \\ b trapEntry      // 0x400: Synchronous
        \\ .balign 128
        \\ b irqEntry       // 0x480: IRQ
        \\ .balign 128
        \\ b trapEntry      // 0x500: FIQ
        \\ .balign 128
        \\ b trapEntry      // 0x580: SError
        \\ .balign 128
        // Lower EL using AArch32 (0x600 - 0x7FF) - not supported, use generic handler
        \\ b trapEntry      // 0x600: Synchronous
        \\ .balign 128
        \\ b trapEntry      // 0x680: IRQ
        \\ .balign 128
        \\ b trapEntry      // 0x700: FIQ
        \\ .balign 128
        \\ b trapEntry      // 0x780: SError
        \\ .balign 128
    );
}

/// Raw trap entry point. Saves all registers and calls Zig handler.
/// On exception entry, ARM64 automatically masks interrupts (PSTATE.{D,A,I,F}
/// set per SCTLR_EL1). SPSR saves old PSTATE, restored by ERET.
export fn trapEntry() callconv(.naked) noreturn {
    // Save all general-purpose registers and system state.
    asm volatile (
    // First, allocate frame and save x0-x1 which we need as scratch
        \\sub sp, sp, #288
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x19, [sp, #144]
        \\stp x20, x21, [sp, #160]
        \\stp x22, x23, [sp, #176]
        \\stp x24, x25, [sp, #192]
        \\stp x26, x27, [sp, #208]
        \\stp x28, x29, [sp, #224]

        // Save x30 and original SP together (contiguous in frame)
        \\add x0, sp, #288
        \\stp x30, x0, [sp, #240]

        // Save ELR and SPSR as pair
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #256]

        // Save ESR and FAR as pair
        \\mrs x0, esr_el1
        \\mrs x1, far_el1
        \\stp x0, x1, [sp, #272]

        // Call Zig trap handler with pointer to context
        \\mov x0, sp
        \\bl handleTrap

        // Restore ELR and SPSR (may have been modified by handler)
        \\ldp x0, x1, [sp, #256]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1

        // Restore general-purpose registers
        \\ldp x0, x1, [sp, #0]
        \\ldp x2, x3, [sp, #16]
        \\ldp x4, x5, [sp, #32]
        \\ldp x6, x7, [sp, #48]
        \\ldp x8, x9, [sp, #64]
        \\ldp x10, x11, [sp, #80]
        \\ldp x12, x13, [sp, #96]
        \\ldp x14, x15, [sp, #112]
        \\ldp x16, x17, [sp, #128]
        \\ldp x18, x19, [sp, #144]
        \\ldp x20, x21, [sp, #160]
        \\ldp x22, x23, [sp, #176]
        \\ldp x24, x25, [sp, #192]
        \\ldp x26, x27, [sp, #208]
        \\ldp x28, x29, [sp, #224]
        \\ldr x30, [sp, #240]

        // Restore SP and return from trap
        \\add sp, sp, #288
        \\eret
    );
}

/// IRQ entry point - optimized fast path saving only caller-saved registers.
/// AAPCS64 guarantees x19-x28 are callee-saved, so handleIrq preserves them.
/// We only save x0-x18, x30 (caller-saved) plus ELR/SPSR for return.
/// Frame: 176 bytes = 20 regs + elr + spsr (16-byte aligned).
export fn irqEntry() callconv(.naked) noreturn {
    asm volatile (
    // Allocate smaller frame for caller-saved registers only
        \\sub sp, sp, #176

        // Save caller-saved registers: x0-x17 (pairs), x18, x30
        \\stp x0, x1, [sp, #0]
        \\stp x2, x3, [sp, #16]
        \\stp x4, x5, [sp, #32]
        \\stp x6, x7, [sp, #48]
        \\stp x8, x9, [sp, #64]
        \\stp x10, x11, [sp, #80]
        \\stp x12, x13, [sp, #96]
        \\stp x14, x15, [sp, #112]
        \\stp x16, x17, [sp, #128]
        \\stp x18, x30, [sp, #144]

        // Save ELR and SPSR for eret (use STP for efficiency)
        \\mrs x0, elr_el1
        \\mrs x1, spsr_el1
        \\stp x0, x1, [sp, #160]

        // Call IRQ handler (no context needed, GIC tells us the interrupt)
        \\bl handleIrq

        // Restore ELR and SPSR (use LDP for efficiency)
        \\ldp x0, x1, [sp, #160]
        \\msr elr_el1, x0
        \\msr spsr_el1, x1

        // Restore caller-saved registers
        \\ldp x0, x1, [sp, #0]
        \\ldp x2, x3, [sp, #16]
        \\ldp x4, x5, [sp, #32]
        \\ldp x6, x7, [sp, #48]
        \\ldp x8, x9, [sp, #64]
        \\ldp x10, x11, [sp, #80]
        \\ldp x12, x13, [sp, #96]
        \\ldp x14, x15, [sp, #112]
        \\ldp x16, x17, [sp, #128]
        \\ldp x18, x30, [sp, #144]
        \\add sp, sp, #176
        \\eret
    );
}

/// Spurious interrupt ID returned by GIC when no interrupt is pending.
const SPURIOUS_INTID: u32 = 1023;

const TIMER_PPI = gic.TIMER_PPI;

/// Handle IRQ - acknowledge, dispatch, end-of-interrupt.
export fn handleIrq() void {
    const intid = gic.acknowledge();

    if (intid == SPURIOUS_INTID) return;

    switch (intid) {
        TIMER_PPI => clock.handleTimerIrq(),
        else => @panic(panic_msg.UNHANDLED_IRQ),
    }

    gic.endOfInterrupt(intid);
}

/// Main trap handler called from assembly entry point.
/// Examines trap cause and either handles it or panics.
export fn handleTrap(ctx: *TrapContext) void {
    // Extract trap class from ESR_EL1[31:26]
    const ec = @as(TrapClass, @enumFromInt(@as(u6, @truncate(ctx.esr >> 26))));

    // Print register dump
    dumpTrap(ctx, ec);

    // For now, all synchronous traps are fatal
    // Later: handle page faults, syscalls, etc.
    @panic(panic_msg.UNHANDLED);
}

/// Print trap information and register dump for debugging.
fn dumpTrap(ctx: *const TrapContext, ec: TrapClass) void {
    // Print trap header
    print("\nTrap: ");
    print(ec.name());
    print(" \n");

    // Print key registers inline
    printKeyRegister("elr", ctx.elr);
    print(" ");
    printKeyRegister("sp", ctx.sp);
    print(" ");
    printKeyRegister("esr", ctx.esr);
    print(" ");
    printKeyRegister("far", ctx.far);
    print("\n");

    // Dump all general-purpose registers
    const reg_names = [_][]const u8{
        "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
        "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
        "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
        "x24", "x25", "x26", "x27", "x28", "x29", "x30",
    };
    for (reg_names, 0..) |reg_name, i| {
        print(&trap.fmt.formatRegName(reg_name));
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

test "TrapContext size and layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 288), TrapContext.FRAME_SIZE);
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

test "TrapContext.getReg returns correct values" {
    const std = @import("std");
    var ctx: TrapContext = undefined;

    // Set up test values
    for (0..31) |i| {
        ctx.regs[i] = @as(u64, i) + 100;
    }

    // Verify getReg returns correct values
    try std.testing.expectEqual(@as(u64, 100), ctx.getReg(0));
    try std.testing.expectEqual(@as(u64, 101), ctx.getReg(1));
    try std.testing.expectEqual(@as(u64, 130), ctx.getReg(30));

    // Out of bounds returns 0
    try std.testing.expectEqual(@as(u64, 0), ctx.getReg(31));
    try std.testing.expectEqual(@as(u64, 0), ctx.getReg(100));
}
