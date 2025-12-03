//! SBI ecall wrappers for OpenSBI firmware.

const std = @import("std");

/// SBI ecall with up to 3 arguments. Returns error if SBI returns negative value.
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

    if (@as(isize, @bitCast(ret)) < 0) {
        return error.SBIError;
    }
    return ret;
}

pub fn legacyConsolePutchar(byte: u8) void {
    _ = call(0x01, 0, byte, 0, 0) catch @panic("SBI console putchar failed");
}
