//! ARM64 context-switch frame.
//!
//! This is the callee-saved register set for voluntary switches, separate from
//! the trap frame used by exceptions. The layout mirrors AAPCS64: x19-x28,
//! x29(fp), x30(lr), sp, and the saved interrupt state.

#![allow(dead_code, reason = "assembly owns context frame fields")]

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
    pub const X19_OFFSET: usize = core::mem::offset_of!(Context, x19);
    pub const X21_OFFSET: usize = core::mem::offset_of!(Context, x21);
    pub const X23_OFFSET: usize = core::mem::offset_of!(Context, x23);
    pub const X25_OFFSET: usize = core::mem::offset_of!(Context, x25);
    pub const X27_OFFSET: usize = core::mem::offset_of!(Context, x27);
    pub const FRAME_POINTER_OFFSET: usize = core::mem::offset_of!(Context, frame_pointer);
    pub const STACK_POINTER_OFFSET: usize = core::mem::offset_of!(Context, stack_pointer);
    pub const IRQ_ENABLED_OFFSET: usize = core::mem::offset_of!(Context, irq_enabled);

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
    fn bullfinch_switch_context_from_trap(old: *mut Context, new: *const Context);
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

/// Switches contexts while already returning through an exception or IRQ frame.
///
/// # Safety
///
/// `old` and `new` must satisfy the same requirements as [`switch_context`].
/// The caller must be on a trap or IRQ path whose final `eret` restores
/// interrupt state from the saved exception status.
pub unsafe fn switch_context_from_trap(old: &mut Context, new: &Context) {
    // SAFETY: The caller proves the context ABI requirements and the trap-return
    // boundary owns interrupt-state restoration.
    unsafe { bullfinch_switch_context_from_trap(old, new) };
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
    stp x19, x20, [x0, #{x19_offset}]
    stp x21, x22, [x0, #{x21_offset}]
    stp x23, x24, [x0, #{x23_offset}]
    stp x25, x26, [x0, #{x25_offset}]
    stp x27, x28, [x0, #{x27_offset}]
    stp x29, x30, [x0, #{frame_pointer_offset}]
    mov x2, sp
    str x2, [x0, #{stack_pointer_offset}]

    ldp x19, x20, [x1, #{x19_offset}]
    ldp x21, x22, [x1, #{x21_offset}]
    ldp x23, x24, [x1, #{x23_offset}]
    ldp x25, x26, [x1, #{x25_offset}]
    ldp x27, x28, [x1, #{x27_offset}]
    ldp x29, x30, [x1, #{frame_pointer_offset}]
    ldr x2, [x1, #{stack_pointer_offset}]
    mov sp, x2

    ldr x2, [x1, #{irq_enabled_offset}]
    cbz x2, 1f
    msr daifclr, #3
    b 2f
1:
    msr daifset, #3
2:
    ret

    .global bullfinch_switch_context_from_trap
    .type bullfinch_switch_context_from_trap, %function
bullfinch_switch_context_from_trap:
    stp x19, x20, [x0, #{x19_offset}]
    stp x21, x22, [x0, #{x21_offset}]
    stp x23, x24, [x0, #{x23_offset}]
    stp x25, x26, [x0, #{x25_offset}]
    stp x27, x28, [x0, #{x27_offset}]
    stp x29, x30, [x0, #{frame_pointer_offset}]
    mov x2, sp
    str x2, [x0, #{stack_pointer_offset}]

    ldp x19, x20, [x1, #{x19_offset}]
    ldp x21, x22, [x1, #{x21_offset}]
    ldp x23, x24, [x1, #{x23_offset}]
    ldp x25, x26, [x1, #{x25_offset}]
    ldp x27, x28, [x1, #{x27_offset}]
    ldp x29, x30, [x1, #{frame_pointer_offset}]
    ldr x2, [x1, #{stack_pointer_offset}]
    mov sp, x2
    ret

    .global bullfinch_thread_trampoline
    .type bullfinch_thread_trampoline, %function
bullfinch_thread_trampoline:
    mov x0, x20
    br x19
"#
    ,
    x19_offset = const Context::X19_OFFSET,
    x21_offset = const Context::X21_OFFSET,
    x23_offset = const Context::X23_OFFSET,
    x25_offset = const Context::X25_OFFSET,
    x27_offset = const Context::X27_OFFSET,
    frame_pointer_offset = const Context::FRAME_POINTER_OFFSET,
    stack_pointer_offset = const Context::STACK_POINTER_OFFSET,
    irq_enabled_offset = const Context::IRQ_ENABLED_OFFSET,
);

const _: () = assert!(core::mem::size_of::<Context>() == Context::SIZE);
const _: () = assert!(core::mem::align_of::<Context>() == 16);
const _: () = assert!(Context::X19_OFFSET == 0);
const _: () = assert!(core::mem::offset_of!(Context, x20) == 8);
const _: () = assert!(Context::FRAME_POINTER_OFFSET == 80);
const _: () = assert!(core::mem::offset_of!(Context, link_register) == 88);
const _: () = assert!(Context::STACK_POINTER_OFFSET == 96);
const _: () = assert!(Context::IRQ_ENABLED_OFFSET == 104);

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
