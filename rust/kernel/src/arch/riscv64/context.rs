//! RISC-V context-switch frame.
//!
//! This is the psABI callee-saved register set for voluntary switches,
//! separate from the trap frame used by exceptions.

#![allow(dead_code)]

use core::arch::global_asm;

#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Context {
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
    return_address: u64,
    stack_pointer: u64,
    irq_enabled: u64,
    pad: [u8; 8],
}

impl Context {
    pub const SIZE: usize = 128;

    pub const fn new(entry_pc: usize, stack_top: usize) -> Self {
        Self {
            return_address: entry_pc as u64,
            stack_pointer: stack_top as u64,
            irq_enabled: 1,
            ..Self::empty()
        }
    }

    pub const fn empty() -> Self {
        Self {
            s0: 0,
            s1: 0,
            s2: 0,
            s3: 0,
            s4: 0,
            s5: 0,
            s6: 0,
            s7: 0,
            s8: 0,
            s9: 0,
            s10: 0,
            s11: 0,
            return_address: 0,
            stack_pointer: 0,
            irq_enabled: 1,
            pad: [0; 8],
        }
    }

    pub fn set_entry_data(&mut self, entry: usize, arg: usize) {
        self.s1 = entry as u64;
        self.s2 = arg as u64;
    }

    pub const fn stack_pointer(self) -> usize {
        self.stack_pointer as usize
    }
}

unsafe extern "C" {
    fn bullfinch_switch_context(old: *mut Context, new: *const Context);
    fn bullfinch_thread_trampoline() -> !;
}

/// Switches from one saved kernel context to another.
///
/// # Safety
///
/// `old` and `new` must point to valid, non-overlapping context records. The
/// incoming context must contain a valid kernel stack and return address. The
/// caller must preserve scheduler invariants because execution resumes on a
/// different stack before this function returns.
pub unsafe fn switch_context(old: &mut Context, new: &Context) {
    // SAFETY: The caller proves that both contexts are valid for the assembly
    // ABI and that switching stacks is allowed at this point.
    unsafe { bullfinch_switch_context(old, new) };
}

pub fn thread_trampoline_address() -> usize {
    bullfinch_thread_trampoline as *const () as usize
}

global_asm!(
    r#"
    .text
    .align 2
    .global bullfinch_switch_context
    .type bullfinch_switch_context, @function
bullfinch_switch_context:
    sd s0, 0(a0)
    sd s1, 8(a0)
    sd s2, 16(a0)
    sd s3, 24(a0)
    sd s4, 32(a0)
    sd s5, 40(a0)
    sd s6, 48(a0)
    sd s7, 56(a0)
    sd s8, 64(a0)
    sd s9, 72(a0)
    sd s10, 80(a0)
    sd s11, 88(a0)
    sd ra, 96(a0)
    sd sp, 104(a0)

    ld s0, 0(a1)
    ld s1, 8(a1)
    ld s2, 16(a1)
    ld s3, 24(a1)
    ld s4, 32(a1)
    ld s5, 40(a1)
    ld s6, 48(a1)
    ld s7, 56(a1)
    ld s8, 64(a1)
    ld s9, 72(a1)
    ld s10, 80(a1)
    ld s11, 88(a1)
    ld ra, 96(a1)
    ld sp, 104(a1)

    ld t0, 112(a1)
    beqz t0, 1f
    csrsi sstatus, 0x2
    j 2f
1:
    csrci sstatus, 0x2
2:
    ret

    .global bullfinch_thread_trampoline
    .type bullfinch_thread_trampoline, @function
bullfinch_thread_trampoline:
    mv a0, s2
    jr s1
"#
);

const _: () = assert!(core::mem::size_of::<Context>() == Context::SIZE);
const _: () = assert!(core::mem::align_of::<Context>() == 16);
const _: () = assert!(core::mem::offset_of!(Context, s0) == 0);
const _: () = assert!(core::mem::offset_of!(Context, s1) == 8);
const _: () = assert!(core::mem::offset_of!(Context, s11) == 88);
const _: () = assert!(core::mem::offset_of!(Context, return_address) == 96);
const _: () = assert!(core::mem::offset_of!(Context, stack_pointer) == 104);
const _: () = assert!(core::mem::offset_of!(Context, irq_enabled) == 112);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initializes_thread_entry_context() {
        let mut context = Context::new(0x1000, 0x8000);
        context.set_entry_data(0x2000, 0x3000);

        assert_eq!(context.return_address, 0x1000);
        assert_eq!(context.stack_pointer(), 0x8000);
        assert_eq!(context.s1, 0x2000);
        assert_eq!(context.s2, 0x3000);
    }
}
