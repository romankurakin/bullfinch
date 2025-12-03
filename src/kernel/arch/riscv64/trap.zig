//! RISC-V trap handling - trap vector and exception handlers.
//!
//! We run in S-mode (kernel). OpenSBI (M-mode) delegates traps to us via stvec.
//! On trap: hardware saves sepc, sstatus, scause, stval and jumps to stvec.
//! We use Direct mode (all traps → same handler, reads scause to dispatch).
//!
//! Reference: RISC-V Privileged Specification Chapter 4 "Supervisor-Level ISA"

const builtin = @import("builtin");

// HAL stub in test mode (register dump needs hal.print, but `zig test` doesn't resolve modules).
const hal = if (builtin.is_test)
    struct {
        pub fn print(_: []const u8) void {}
    }
else
    @import("board").hal;

/// Saved register context during trap. Layout must match assembly save/restore order
/// (extern struct guarantees field order). RISC-V ABI: a0-a7 args, s0-s11 callee-saved, ra return addr.
pub const TrapContext = extern struct {
    regs: [31]u64, // x1-x31 (x0 hardwired to 0, not saved)
    sp: u64, // Stack pointer
    sepc: u64, // Supervisor Exception PC (return address)
    sstatus: u64, // Supervisor Status (privilege, interrupt enable)
    scause: u64, // Supervisor Cause (bit 63: interrupt, lower: code)
    stval: u64, // Supervisor Trap Value (fault address or instruction)

    pub const FRAME_SIZE = @sizeOf(TrapContext);

    comptime {
        if (FRAME_SIZE != 288) { // 31 + sp + sepc + sstatus + scause + stval = 36 × 8
            @compileError("TrapContext size mismatch - update assembly!");
        }
    }

    pub fn getReg(self: *const TrapContext, idx: usize) u64 {
        if (idx == 0) return 0; // x0 is always zero
        return self.regs[idx - 1];
    }
};

/// Trap cause from scause CSR. Bit 63: interrupt (1) vs exception (0).
/// RISC-V Privileged Spec Table 4.2.
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
    ecall_from_vs = 10,
    ecall_from_m = 11,
    instruction_page_fault = 12,
    load_page_fault = 13,
    reserved_14 = 14,
    store_page_fault = 15,
    instruction_guest_page_fault = 20,
    load_guest_page_fault = 21,
    virtual_instruction = 22,
    store_guest_page_fault = 23,

    supervisor_software_interrupt = 0x8000000000000001, // Interrupts have bit 63 set
    supervisor_timer_interrupt = 0x8000000000000005,
    supervisor_external_interrupt = 0x8000000000000009,

    _,

    pub fn isInterrupt(cause: u64) bool {
        return (cause >> 63) == 1;
    }

    pub fn code(cause: u64) u64 {
        return cause & ~(@as(u64, 1) << 63);
    }

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
            .ecall_from_u => "environment call from u-mode",
            .ecall_from_s => "environment call from s-mode",
            .ecall_from_vs => "environment call from vs-mode",
            .ecall_from_m => "environment call from m-mode",
            .instruction_page_fault => "instruction page fault",
            .load_page_fault => "load page fault",
            .store_page_fault => "store page fault",
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

/// Trap entry point (naked function, linksection for 4-byte alignment).
/// Stack frame: 288 bytes (x1-x31, sp, sepc, sstatus, scause, stval).
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

        // Read and save scause
        \\csrr t0, scause
        \\sd t0, 272(sp)

        // Read and save stval
        \\csrr t0, stval
        \\sd t0, 280(sp)

        // Call Zig trap handler with pointer to context
        \\mv a0, sp
        \\call handleTrap

        // Handler returned - restore registers
        // Note: For now handler panics, but we include restore for future use

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

/// Main trap handler - examines scause and dispatches or panics.
export fn handleTrap(ctx: *TrapContext) void {
    const cause = @as(TrapCause, @enumFromInt(ctx.scause));

    // Print register dump
    dumpTrap(ctx, cause);

    // For now, all traps are fatal
    // Later: handle page faults, syscalls, timer interrupts, etc.
    @panic("Unhandled trap");
}

fn dumpTrap(ctx: *const TrapContext, cause: TrapCause) void {
    hal.print("trap: ");
    hal.print(cause.name());
    hal.print("\n");

    hal.print("sepc   =0x");
    printHex(ctx.sepc);
    hal.print(" sp     =0x");
    printHex(ctx.sp);
    hal.print(" scause =0x");
    printHex(ctx.scause);
    hal.print(" stval  =0x");
    printHex(ctx.stval);
    hal.print("\n");

    const reg_names = [_][]const u8{
        "ra", "sp",  "gp",  "tp", "t0", "t1", "t2", "s0",
        "s1", "a0",  "a1",  "a2", "a3", "a4", "a5", "a6",
        "a7", "s2",  "s3",  "s4", "s5", "s6", "s7", "s8",
        "s9", "s10", "s11", "t3", "t4", "t5", "t6",
    };

    var i: usize = 0;
    while (i < 31) : (i += 4) {
        // Register 1
        printRegName(reg_names[i]);
        hal.print("=0x");
        printHex(ctx.regs[i]);

        // Register 2
        if (i + 1 < 31) {
            hal.print(" ");
            printRegName(reg_names[i + 1]);
            hal.print("=0x");
            printHex(ctx.regs[i + 1]);
        }

        // Register 3
        if (i + 2 < 31) {
            hal.print(" ");
            printRegName(reg_names[i + 2]);
            hal.print("=0x");
            printHex(ctx.regs[i + 2]);
        }

        // Register 4
        if (i + 3 < 31) {
            hal.print(" ");
            printRegName(reg_names[i + 3]);
            hal.print("=0x");
            printHex(ctx.regs[i + 3]);
        }

        hal.print("\n");
    }
}

fn printRegName(name: []const u8) void {
    hal.print(name);
    // Pad to 7 characters for consistent alignment
    var padding = 7 - name.len;
    while (padding > 0) : (padding -= 1) {
        hal.print(" ");
    }
}

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

/// Initialize trap handling by installing stvec (Direct mode).
pub fn init() void {
    const stvec_val = @intFromPtr(&trapEntry);

    // stvec format: [63:2] address, [1:0] mode (00=Direct, 01=Vectored)
    // Direct mode: all traps → same handler, reads scause to dispatch (simpler, standard for educational kernels).
    if (stvec_val & 0x3 != 0) {
        @panic("Trap entry not 4-byte aligned!");
    }

    asm volatile ("csrw stvec, %[stvec]"
        :
        : [stvec] "r" (stvec_val),
    );
    asm volatile ("fence.i"); // Ensure icache sees stvec code
}

/// Trigger breakpoint exception for testing (EBREAK → scause=3).
pub fn testTriggerBreakpoint() void {
    asm volatile ("ebreak");
}

/// Trigger illegal instruction exception (all-zeros is illegal on RISC-V).
pub fn testTriggerIllegal() void {
    asm volatile (".word 0x00000000");
}

/// Disable interrupts and halt CPU (for panic/fatal error handling).
pub fn halt() noreturn {
    asm volatile ("csrci sstatus, 0x2"); // Clear SIE bit (disable interrupts)
    while (true) {
        asm volatile ("wfi");
    }
}

test "TrapContext size is correct" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 288), TrapContext.FRAME_SIZE);
}

test "TrapCause interrupt detection" {
    const std = @import("std");
    try std.testing.expect(TrapCause.isInterrupt(0x8000000000000005));
    try std.testing.expect(!TrapCause.isInterrupt(0x0000000000000005));
    try std.testing.expectEqual(@as(u64, 5), TrapCause.code(0x8000000000000005));
    try std.testing.expectEqual(@as(u64, 5), TrapCause.code(0x0000000000000005));
}

test "TrapCause names are defined" {
    const std = @import("std");
    try std.testing.expect(TrapCause.breakpoint.name().len > 0);
    try std.testing.expect(TrapCause.ecall_from_u.name().len > 0);
    try std.testing.expect(TrapCause.load_page_fault.name().len > 0);
}
