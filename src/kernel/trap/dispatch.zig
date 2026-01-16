//! Trap Classification.
//!
//! Maps architecture-specific trap causes to common categories. Each architecture
//! implements classify() to decode its cause register (ESR_EL1 or scause).
//!
//! TODO(syscall): Route syscalls to handler.
//! TODO(vm): Route page faults to VM subsystem.
//! TODO(scheduler): Route timer IRQs to scheduler.

const builtin = @import("builtin");
const std = @import("std");
const trap_frame = @import("trap_frame.zig");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/trap_frame.zig"),
    .riscv64 => @import("../arch/riscv64/trap_frame.zig"),
    else => @compileError("Unsupported architecture"),
};

const TrapFrame = trap_frame.TrapFrame;

/// Architecture-independent trap classification.
pub const TrapKind = enum {
    /// System call from userspace (SVC on ARM64, ECALL on RISC-V).
    syscall,

    /// Page fault - instruction fetch, load, or store to unmapped/protected page.
    page_fault,

    /// Alignment fault - unaligned access where alignment required.
    alignment_fault,

    /// Illegal or undefined instruction.
    illegal_instruction,

    /// Debug breakpoint (BRK on ARM64, EBREAK on RISC-V).
    breakpoint,

    /// Timer interrupt from platform timer.
    timer_irq,

    /// External device interrupt (via GIC or PLIC).
    external_irq,

    /// Software interrupt / IPI.
    software_irq,

    /// Trap cause not recognized or not yet implemented.
    unknown,
};

/// Additional information about the trap beyond its kind.
pub const TrapInfo = struct {
    kind: TrapKind,
    /// For page_fault: the faulting address. For external_irq: the IRQ number.
    /// Zero for traps where this field is not applicable.
    aux: usize = 0,
};

/// Classify trap based on architecture-specific cause register.
pub fn classify(frame: *const TrapFrame) TrapInfo {
    return arch.classify(frame);
}

/// Get human-readable name for trap kind.
pub fn kindName(kind: TrapKind) []const u8 {
    return switch (kind) {
        .syscall => "syscall",
        .page_fault => "page fault",
        .alignment_fault => "alignment fault",
        .illegal_instruction => "illegal instruction",
        .breakpoint => "breakpoint",
        .timer_irq => "timer interrupt",
        .external_irq => "external interrupt",
        .software_irq => "software interrupt",
        .unknown => "unknown trap",
    };
}

test "TrapKind covers common trap types" {
    // Verify we have the expected kinds
    try std.testing.expect(@intFromEnum(TrapKind.syscall) != @intFromEnum(TrapKind.page_fault));
    try std.testing.expect(@intFromEnum(TrapKind.timer_irq) != @intFromEnum(TrapKind.external_irq));
}

test "kindName returns non-empty strings" {
    inline for (std.meta.fields(TrapKind)) |field| {
        const kind: TrapKind = @enumFromInt(field.value);
        try std.testing.expect(kindName(kind).len > 0);
    }
}
