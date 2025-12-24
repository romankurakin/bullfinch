//! ARM64 trap handling - exception vector table and handlers.
//!
//! ARM64 terminology: "exceptions" (we use "trap" to match RISC-V/OS theory).
//! Vector table: 16 entries (4 types × 4 sources), 2KB aligned, 128 bytes each.
//! Types: Synchronous, IRQ, FIQ, SError | Sources: Current/Lower EL, SP0/SPx, A64/A32
//!
//! Reference: ARM DDI 0487 Chapter D1 "The AArch64 Exception Model"

const trap_common = @import("../../trap_common.zig");
const hal = trap_common.hal;

/// Saved register context during trap. Layout must match assembly save/restore order
/// (extern struct guarantees field order). ARM AAPCS64: x0-x7 args, x19-x28 callee-saved, x29 FP, x30 LR.
pub const TrapContext = extern struct {
    regs: [31]u64, // x0-x30
    sp: u64, // Stack pointer at time of exception
    elr: u64, // Exception Link Register (return address)
    spsr: u64, // Saved Program Status Register
    esr: u64, // Exception Syndrome Register (cause)
    far: u64, // Fault Address Register (for memory aborts)

    pub const FRAME_SIZE = @sizeOf(TrapContext);

    comptime {
        if (FRAME_SIZE != 288) { // 31 + sp + elr + spsr + esr + far = 36 × 8
            @compileError("TrapContext size mismatch - update assembly!");
        }
    }

    pub fn getReg(self: *const TrapContext, idx: usize) u64 {
        if (idx >= 31) return 0;
        return self.regs[idx];
    }
};

/// Exception class from ESR_EL1[31:26] (ARM DDI 0487 Table D1-6).
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
    ld64b_st64b = 0x0A,
    cp14_mrrc = 0x0C,
    branch_target = 0x0D,
    illegal_state = 0x0E,
    svc_aarch32 = 0x11,
    hvc_aarch64 = 0x16,
    smc_aarch64 = 0x17,
    svc_aarch64 = 0x15,
    msr_mrs_sys = 0x18,
    sve = 0x19,
    eret = 0x1A,
    tstart_fail = 0x1B,
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
    vector32 = 0x3A,
    brk_aarch64 = 0x3C,
    _,

    pub fn name(self: TrapClass) []const u8 {
        return switch (self) {
            .unknown => "unknown exception",
            .wfi_wfe => "wfi/wfe trapped",
            .simd_fp => "simd/fp access",
            .svc_aarch64 => "svc (syscall)",
            .hvc_aarch64 => "hvc (hypervisor call)",
            .smc_aarch64 => "smc (secure monitor call)",
            .msr_mrs_sys => "msr/mrs/sys trapped",
            .tstart_fail => "tstart failure",
            .inst_abort_lower => "instruction abort (lower el)",
            .inst_abort_same => "instruction abort (same el)",
            .pc_align => "pc alignment fault",
            .data_abort_lower => "data abort (lower el)",
            .data_abort_same => "data abort (same el)",
            .sp_align => "sp alignment fault",
            .serror => "serror",
            .breakpoint_lower => "breakpoint (lower el)",
            .breakpoint_same => "breakpoint (same el)",
            .brk_aarch64 => "brk instruction",
            else => "other exception",
        };
    }
};

// Trap Vector Table

/// VBAR_EL1 requires 2KB alignment (bits [10:0] = 0).
const VBAR_ALIGNMENT = 2048;

/// Trap vector table - must be 2KB aligned per ARM spec.
/// 16 entries × 128 bytes each. Each entry branches to trapEntry.
/// Static assembly - no runtime patching needed, linker resolves offsets.
export fn trap_vectors() align(VBAR_ALIGNMENT) linksection(".vectors") callconv(.naked) void {
    // 16 vector entries, each 128 bytes (32 instructions).
    // We use b (branch) + padding. Assembler/linker handles offset calculation.
    asm volatile (
        // Current EL with SP_EL0 (0x000 - 0x1FF)
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        // Current EL with SP_ELx (0x200 - 0x3FF)
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        // Lower EL using AArch64 (0x400 - 0x5FF)
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        // Lower EL using AArch32 (0x600 - 0x7FF)
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
        \\ b trapEntry
        \\ .balign 128
    );
}

// Trap Entry Point (naked function)

/// Raw trap entry point. Saves all registers and calls Zig handler.
/// This function is naked to give us full control over register usage.
/// Called from vector table entries.
///
/// Stack frame layout (growing down from high address):
/// +288: [previous SP]
/// +280: FAR_EL1 (filled by handler)
/// +272: ESR_EL1 (filled by handler)
/// +264: SPSR_EL1
/// +256: ELR_EL1
/// +248: SP (original)
/// +240: x30
/// +232: x29
/// ...
/// +  0: x0
///
/// NOTE: On exception entry, ARM64 automatically masks interrupts (PSTATE.{D,A,I,F}
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
        \\str x30, [sp, #240]

        // Calculate and save original SP (SP before sub #288)
        \\add x0, sp, #288
        \\str x0, [sp, #248]

        // Save ELR_EL1 (return address)
        \\mrs x0, elr_el1
        \\str x0, [sp, #256]

        // Save SPSR_EL1 (saved program status)
        \\mrs x0, spsr_el1
        \\str x0, [sp, #264]

        // Read and save ESR_EL1 (exception syndrome)
        \\mrs x0, esr_el1
        \\str x0, [sp, #272]

        // Read and save FAR_EL1 (fault address)
        \\mrs x0, far_el1
        \\str x0, [sp, #280]

        // Call Zig trap handler with pointer to context
        \\mov x0, sp
        \\bl handleTrap

        // Handler returned - restore registers
        // Note: For now handler panics, but we include restore for future use

        // Restore ELR and SPSR first (may have been modified by handler)
        \\ldr x0, [sp, #256]
        \\msr elr_el1, x0
        \\ldr x0, [sp, #264]
        \\msr spsr_el1, x0

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

// Trap Handler

/// Main trap handler called from assembly entry point.
/// Examines trap cause and either handles it or panics.
export fn handleTrap(ctx: *TrapContext) void {
    // Extract trap class from ESR_EL1[31:26]
    const ec = @as(TrapClass, @enumFromInt(@as(u6, @truncate(ctx.esr >> 26))));

    // Print register dump
    dumpTrap(ctx, ec);

    // For now, all traps are fatal
    // Later: handle page faults, syscalls, etc.
    @panic("Unhandled trap");
}

// Register Dump

/// Print trap information and register dump for debugging.
fn dumpTrap(ctx: *const TrapContext, ec: TrapClass) void {
    trap_common.printTrapHeader(ec.name());

    trap_common.printKeyRegister("elr", ctx.elr);
    hal.print(" ");
    trap_common.printKeyRegister("sp", ctx.sp);
    hal.print(" ");
    trap_common.printKeyRegister("esr", ctx.esr);
    hal.print(" ");
    trap_common.printKeyRegister("far", ctx.far);
    hal.print("\n");

    const reg_names = [_][]const u8{
        "x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",  "x7",
        "x8",  "x9",  "x10", "x11", "x12", "x13", "x14", "x15",
        "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
        "x24", "x25", "x26", "x27", "x28", "x29", "x30",
    };

    trap_common.dumpRegisters(&ctx.regs, &reg_names);
}

// Initialization

/// Initialize trap handling by installing the vector table.
/// Must be called early in kernel init, after UART but before anything
/// that might cause a trap.
pub fn init() void {
    const vbar = @intFromPtr(&trap_vectors);

    // Write VBAR_EL1 with vector table address
    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );

    // ISB ensures the VBAR write completes before any trap could occur.
    asm volatile ("isb");
}

// Test Helpers

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

/// Disable interrupts and halt CPU (for panic/fatal error handling).
pub fn halt() noreturn {
    asm volatile ("msr daifset, #0xF"); // Disable all interrupts (D, A, I, F)
    while (true) {
        asm volatile ("wfi");
    }
}

// Unit Tests

test "TrapContext size is correct" {
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
