//! ARM64 trap handling - exception vector table and handlers.
//!
//! ARM64 terminology: "exceptions" (we use "trap" to match RISC-V/OS theory).
//! Vector table: 16 entries (4 types × 4 sources), 2KB aligned, 128 bytes each.
//! Types: Synchronous, IRQ, FIQ, SError | Sources: Current/Lower EL, SP0/SPx, A64/A32
//!
//! Reference: ARM DDI 0487 Chapter D1 "The AArch64 Exception Model"

const builtin = @import("builtin");

// HAL stub in test mode (register dump needs hal.print, but `zig test` doesn't resolve modules).
const hal = if (builtin.is_test)
    struct {
        pub fn print(_: []const u8) void {}
    }
else
    @import("board").hal;

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
    ptrauth = 0x09,
    ld64b_st64b = 0x0A,
    cp14_mrrc = 0x0C,
    branch_target = 0x0D,
    illegal_state = 0x0E,
    svc_aarch32 = 0x11,
    svc_aarch64 = 0x15,
    msr_mrs_sys = 0x18,
    sve = 0x19,
    eret = 0x1A,
    pac_fail = 0x1C,
    inst_abort_lower = 0x20,
    inst_abort_same = 0x21,
    pc_align = 0x22,
    data_abort_lower = 0x24,
    data_abort_same = 0x25,
    sp_align = 0x26,
    fp_aarch32 = 0x28,
    fp_aarch64 = 0x2C,
    serror = 0x2F,
    breakpoint_lower = 0x30,
    breakpoint_same = 0x31,
    step_lower = 0x32,
    step_same = 0x33,
    watchpoint_lower = 0x34,
    watchpoint_same = 0x35,
    bkpt_aarch32 = 0x38,
    brk_aarch64 = 0x3C,
    _,

    pub fn name(self: TrapClass) []const u8 {
        return switch (self) {
            .unknown => "Unknown exception",
            .wfi_wfe => "WFI/WFE trapped",
            .simd_fp => "SIMD/FP access",
            .svc_aarch64 => "SVC (syscall)",
            .msr_mrs_sys => "MSR/MRS/SYS trapped",
            .inst_abort_lower => "Instruction abort (lower EL)",
            .inst_abort_same => "Instruction abort (same EL)",
            .pc_align => "PC alignment fault",
            .data_abort_lower => "Data abort (lower EL)",
            .data_abort_same => "Data abort (same EL)",
            .sp_align => "SP alignment fault",
            .serror => "SError",
            .breakpoint_lower => "Breakpoint (lower EL)",
            .breakpoint_same => "Breakpoint (same EL)",
            .brk_aarch64 => "BRK instruction",
            else => "Other exception",
        };
    }
};

// Trap Vector Table

/// ARM64 vector table offsets. Each entry is 128 bytes (0x80).
/// Table has 4 groups of 4 vectors = 16 entries total.
const VectorOffset = struct {
    // Current EL with SP_EL0 (unusual - kernel using user stack)
    const CURR_EL_SP0_SYNC: usize = 0x000;
    const CURR_EL_SP0_IRQ: usize = 0x080;
    const CURR_EL_SP0_FIQ: usize = 0x100;
    const CURR_EL_SP0_SERROR: usize = 0x180;
    // Current EL with SP_ELx (normal kernel operation)
    const CURR_EL_SPX_SYNC: usize = 0x200;
    const CURR_EL_SPX_IRQ: usize = 0x280;
    const CURR_EL_SPX_FIQ: usize = 0x300;
    const CURR_EL_SPX_SERROR: usize = 0x380;
    // Lower EL using AArch64 (user → kernel)
    const LOWER_EL_A64_SYNC: usize = 0x400;
    const LOWER_EL_A64_IRQ: usize = 0x480;
    const LOWER_EL_A64_FIQ: usize = 0x500;
    const LOWER_EL_A64_SERROR: usize = 0x580;
    // Lower EL using AArch32 (not used in Bullfinch)
    const LOWER_EL_A32_SYNC: usize = 0x600;
    const LOWER_EL_A32_IRQ: usize = 0x680;
    const LOWER_EL_A32_FIQ: usize = 0x700;
    const LOWER_EL_A32_SERROR: usize = 0x780;
};

/// Each vector entry gets 128 bytes (32 instructions).
/// We use a simple branch to shared handler since 128 bytes is tight.
const VECTOR_ENTRY_SIZE = 128;
const VECTOR_TABLE_SIZE = 2048; // 16 entries × 128 bytes

/// Trap vector table - must be 2KB aligned per ARM spec.
/// Alignment enforced by linker script (.vectors : ALIGN(2048)).
/// Initialized to zeros at comptime; branch instructions patched at runtime by init().
export var trap_vectors: [VECTOR_TABLE_SIZE]u8 linksection(".vectors") = [_]u8{0} ** VECTOR_TABLE_SIZE;

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
    hal.print("TRAP: ");
    hal.print(ec.name());
    hal.print("\nELR=0x");
    printHex(ctx.elr);
    hal.print(" SP=0x");
    printHex(ctx.sp);
    hal.print(" ESR=0x");
    printHex(ctx.esr);
    hal.print(" FAR=0x");
    printHex(ctx.far);
    hal.print("\n");

    var i: usize = 0;
    while (i < 31) : (i += 2) {
        hal.print("x");
        printDecimal(i);
        if (i < 10) hal.print(" ");
        hal.print("=0x");
        printHex(ctx.regs[i]);

        if (i + 1 < 31) {
            hal.print(" x");
            printDecimal(i + 1);
            if (i + 1 < 10) hal.print(" ");
            hal.print("=0x");
            printHex(ctx.regs[i + 1]);
        }
        hal.print("\n");
    }
}

/// Print a 64-bit value as hex.
fn printHex(val: u64) void {
    const hex_chars = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @truncate(v & 0xF))];
        v >>= 4;
    }
    hal.print(&buf);
}

/// Print a decimal number (for register indices).
fn printDecimal(val: usize) void {
    if (val >= 10) {
        var buf: [2]u8 = undefined;
        buf[0] = @as(u8, @truncate('0' + (val / 10)));
        buf[1] = @as(u8, @truncate('0' + (val % 10)));
        hal.print(&buf);
    } else {
        var buf: [1]u8 = undefined;
        buf[0] = @as(u8, @truncate('0' + val));
        hal.print(&buf);
    }
}

// Initialization

/// Initialize trap handling by installing the vector table.
/// Must be called early in kernel init, after UART but before anything
/// that might cause a trap.
pub fn init() void {
    // Get vector table address
    const vbar = @intFromPtr(&trap_vectors);

    // Verify alignment - VBAR_EL1 requires bits [10:0] = 0 (2KB alignment)
    if (vbar & 0x7FF != 0) {
        @panic("Trap vector table not 2KB aligned!");
    }

    // Install branch instructions to trapEntry at start of each vector
    // B instruction: 0x14000000 | (signed_offset_in_instructions & 0x3FFFFFF)
    const entry_addr = @intFromPtr(&trapEntry);

    inline for (.{
        VectorOffset.CURR_EL_SP0_SYNC,
        VectorOffset.CURR_EL_SP0_IRQ,
        VectorOffset.CURR_EL_SP0_FIQ,
        VectorOffset.CURR_EL_SP0_SERROR,
        VectorOffset.CURR_EL_SPX_SYNC,
        VectorOffset.CURR_EL_SPX_IRQ,
        VectorOffset.CURR_EL_SPX_FIQ,
        VectorOffset.CURR_EL_SPX_SERROR,
        VectorOffset.LOWER_EL_A64_SYNC,
        VectorOffset.LOWER_EL_A64_IRQ,
        VectorOffset.LOWER_EL_A64_FIQ,
        VectorOffset.LOWER_EL_A64_SERROR,
        VectorOffset.LOWER_EL_A32_SYNC,
        VectorOffset.LOWER_EL_A32_IRQ,
        VectorOffset.LOWER_EL_A32_FIQ,
        VectorOffset.LOWER_EL_A32_SERROR,
    }) |offset| {
        const vector_addr = vbar + offset;
        // Calculate offset from this vector entry to trapEntry
        // Offset is in bytes, must divide by 4 for instruction count
        const byte_offset = @as(i64, @intCast(entry_addr)) - @as(i64, @intCast(vector_addr));
        const insn_offset = @divExact(byte_offset, 4);

        // Verify offset fits in 26-bit signed immediate
        if (insn_offset < -0x2000000 or insn_offset >= 0x2000000) {
            @panic("Trap entry too far from vector table!");
        }

        // Encode B instruction
        const imm26 = @as(u32, @truncate(@as(u64, @bitCast(insn_offset)) & 0x3FFFFFF));
        const b_insn: u32 = 0x14000000 | imm26;

        // Write instruction to vector table (little-endian)
        const ptr: *volatile u32 = @ptrFromInt(vector_addr);
        ptr.* = b_insn;
    }

    // Write VBAR_EL1 with vector table address
    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (vbar),
    );

    // ISB ensures the VBAR write completes before any trap could occur.
    // Without this barrier, a trap taken immediately after could use
    // the old (possibly invalid) vector table address.
    asm volatile ("isb");
}

// Test Helpers

/// Trigger a synchronous trap for testing (BRK instruction).
/// BRK #0 generates EC=0x3C (brk_aarch64) in ESR_EL1.
pub fn testTriggerBreakpoint() void {
    asm volatile ("brk #0");
}

/// Trigger undefined instruction trap for testing.
/// Uses UDF instruction which is guaranteed undefined on all ARM implementations.
pub fn testTriggerUndefined() void {
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

test "TrapClass names are defined" {
    const std = @import("std");
    try std.testing.expect(TrapClass.brk_aarch64.name().len > 0);
    try std.testing.expect(TrapClass.svc_aarch64.name().len > 0);
    try std.testing.expect(TrapClass.data_abort_same.name().len > 0);
}
