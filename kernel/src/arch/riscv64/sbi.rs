//! RISC-V Supervisor Binary Interface calls.
//!
//! The kernel requests firmware services through `ecall`. OpenSBI implements
//! these calls for the QEMU boot path, including timer deadlines and early
//! console output.

use core::arch::asm;

const EXTENSION_TIMER: usize = 0x5449_4d45;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SbiError(isize);

pub fn set_timer(deadline: u64) -> Result<(), SbiError> {
    call(EXTENSION_TIMER, 0, deadline as usize, 0, 0).map(|_| ())
}

fn call(
    extension: usize,
    function: usize,
    arg0: usize,
    arg1: usize,
    arg2: usize,
) -> Result<usize, SbiError> {
    let error_raw: usize;
    let value: usize;

    // SAFETY: `ecall` transfers control to the SBI implementation. Arguments
    // follow the SBI calling convention: a0-a2 for parameters, a6 for function,
    // a7 for extension, with error/value returned in a0/a1.
    unsafe {
        asm!(
            "ecall",
            inlateout("a0") arg0 => error_raw,
            inlateout("a1") arg1 => value,
            in("a2") arg2,
            in("a6") function,
            in("a7") extension,
        );
    }

    let error = error_raw as isize;
    if error < 0 {
        Err(SbiError(error))
    } else {
        Ok(value)
    }
}
