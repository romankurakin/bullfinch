//! Trap Frame HAL.
//!
//! Provides architecture-independent access to saved register state during traps.
//! The TrapFrame struct layout must exactly match the assembly save/restore order
//! in each arch's trap_entry.zig.
//!
//! Frame pointer walking differs by architecture:
//! - ARM64: [fp + 0] = prev_fp, [fp + 8] = ra (AAPCS64)
//! - RISC-V: [fp - 16] = prev_fp, [fp - 8] = ra (psABI)
//!
//! See ARM Architecture Reference Manual D1.4, RISC-V psABI Chapter 2.

const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/trap_frame.zig"),
    .riscv64 => @import("../arch/riscv64/trap_frame.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const TrapFrame = arch.TrapFrame;
pub const readStackFrame = arch.readStackFrame;

// Verify arch implementation provides required interface.
comptime {
    const T = TrapFrame;

    // Size and alignment requirements
    if (!@hasDecl(T, "FRAME_SIZE"))
        @compileError("TrapFrame must have FRAME_SIZE constant");
    if (T.FRAME_SIZE != @sizeOf(T))
        @compileError("TrapFrame.FRAME_SIZE must match @sizeOf(TrapFrame)");
    if (T.FRAME_SIZE & 0xF != 0)
        @compileError("TrapFrame.FRAME_SIZE must be 16-byte aligned");

    // Required methods
    if (!@hasDecl(T, "pc")) @compileError("TrapFrame must have pc method");
    if (!@hasDecl(T, "setPc")) @compileError("TrapFrame must have setPc method");
    if (!@hasDecl(T, "sp")) @compileError("TrapFrame must have sp method");
    if (!@hasDecl(T, "fp")) @compileError("TrapFrame must have fp method");
    if (!@hasDecl(T, "cause")) @compileError("TrapFrame must have cause method");
    if (!@hasDecl(T, "faultAddr")) @compileError("TrapFrame must have faultAddr method");
    if (!@hasDecl(T, "isFromUser")) @compileError("TrapFrame must have isFromUser method");
    if (!@hasDecl(T, "getReg")) @compileError("TrapFrame must have getReg method");

    // Syscall interface
    if (!@hasDecl(T, "syscallNum")) @compileError("TrapFrame must have syscallNum method");
    if (!@hasDecl(T, "syscallArg")) @compileError("TrapFrame must have syscallArg method");
    if (!@hasDecl(T, "setSyscallRet")) @compileError("TrapFrame must have setSyscallRet method");

    // Backtrace support (standalone function, not on TrapFrame)
    if (!@hasDecl(arch, "readStackFrame")) @compileError("arch must have readStackFrame function");
}
