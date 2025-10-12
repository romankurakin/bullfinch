//! Thin wrappers for issuing SBI ecalls from the kernel.
//! Documentation can be found at: https://github.com/riscv-non-isa/riscv-sbi-doc/releases/latest/download/riscv-sbi.pdf

const std = @import("std");

/// Performs an SBI ecall with up to three arguments.
/// Callers must obey the SBI specification for the chosen extension and ensure
/// that the privileged firmware advertises support.
pub fn call(eid: usize, fid: usize, arg0: usize, arg1: usize, arg2: usize) !usize {
    var ret: usize = undefined;
    asm volatile ("ecall"
        : [ret] "={a0}" (ret),
        : [eid] "{a7}" (eid),
          [fid] "{a6}" (fid),
          [a0] "{a0}" (arg0),
          [a1] "{a1}" (arg1),
          [a2] "{a2}" (arg2),
    );

    // SBI returns negative values for errors.
    if (@as(isize, @bitCast(ret)) < 0) {
        return error.SBIError;
    }
    return ret;
}

/// Legacy SBI console putchar (EID 0x01, FID 0).
pub fn legacyConsolePutchar(byte: u8) void {
    _ = call(0x01, 0, byte, 0, 0) catch @panic("SBI console putchar failed");
}
