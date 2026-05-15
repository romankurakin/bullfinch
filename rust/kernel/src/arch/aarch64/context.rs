//! ARM64 context-switch frame.
//!
//! This is the callee-saved register set for voluntary switches, separate from
//! the trap frame used by exceptions. The layout mirrors AAPCS64: x19-x28,
//! x29(fp), x30(lr), sp, and the saved interrupt state.

#![allow(dead_code)]

use core::arch::global_asm;

#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Context {
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    frame_pointer: u64,
    link_register: u64,
    stack_pointer: u64,
    irq_enabled: u64,
    pad: [u8; 16],
}

impl Context {
    pub const SIZE: usize = 128;

    pub const fn new(entry_pc: usize, stack_top: usize) -> Self {
        Self {
            link_register: entry_pc as u64,
            stack_pointer: stack_top as u64,
            irq_enabled: 1,
            ..Self::empty()
        }
    }

    pub const fn empty() -> Self {
        Self {
            x19: 0,
            x20: 0,
            x21: 0,
            x22: 0,
            x23: 0,
            x24: 0,
            x25: 0,
            x26: 0,
            x27: 0,
            x28: 0,
            frame_pointer: 0,
            link_register: 0,
            stack_pointer: 0,
            irq_enabled: 1,
            pad: [0; 16],
        }
    }

    pub fn set_entry_data(&mut self, entry: usize, arg: usize) {
        self.x19 = entry as u64;
        self.x20 = arg as u64;
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
    .type bullfinch_switch_context, %function
bullfinch_switch_context:
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x2, sp
    str x2, [x0, #96]

    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]
    ldr x2, [x1, #96]
    mov sp, x2

    ldr x2, [x1, #104]
    cbz x2, 1f
    msr daifclr, #3
    b 2f
1:
    msr daifset, #3
2:
    ret

    .global bullfinch_thread_trampoline
    .type bullfinch_thread_trampoline, %function
bullfinch_thread_trampoline:
    mov x0, x20
    br x19
"#
);

const _: () = assert!(core::mem::size_of::<Context>() == Context::SIZE);
const _: () = assert!(core::mem::align_of::<Context>() == 16);
const _: () = assert!(core::mem::offset_of!(Context, x19) == 0);
const _: () = assert!(core::mem::offset_of!(Context, x20) == 8);
const _: () = assert!(core::mem::offset_of!(Context, frame_pointer) == 80);
const _: () = assert!(core::mem::offset_of!(Context, link_register) == 88);
const _: () = assert!(core::mem::offset_of!(Context, stack_pointer) == 96);
const _: () = assert!(core::mem::offset_of!(Context, irq_enabled) == 104);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initializes_thread_entry_context() {
        let mut context = Context::new(0x1000, 0x8000);
        context.set_entry_data(0x2000, 0x3000);

        assert_eq!(context.link_register, 0x1000);
        assert_eq!(context.stack_pointer(), 0x8000);
        assert_eq!(context.x19, 0x2000);
        assert_eq!(context.x20, 0x3000);
    }
}
