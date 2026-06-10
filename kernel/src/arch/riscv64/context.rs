//! RISC-V context-switch frame.
//!
//! This is the psABI callee-saved register set for voluntary switches,
//! separate from the trap frame used by exceptions.

#![allow(dead_code, reason = "assembly owns context frame fields")]

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
    pub const S0_OFFSET: usize = core::mem::offset_of!(Context, s0);
    pub const S1_OFFSET: usize = core::mem::offset_of!(Context, s1);
    pub const S2_OFFSET: usize = core::mem::offset_of!(Context, s2);
    pub const S3_OFFSET: usize = core::mem::offset_of!(Context, s3);
    pub const S4_OFFSET: usize = core::mem::offset_of!(Context, s4);
    pub const S5_OFFSET: usize = core::mem::offset_of!(Context, s5);
    pub const S6_OFFSET: usize = core::mem::offset_of!(Context, s6);
    pub const S7_OFFSET: usize = core::mem::offset_of!(Context, s7);
    pub const S8_OFFSET: usize = core::mem::offset_of!(Context, s8);
    pub const S9_OFFSET: usize = core::mem::offset_of!(Context, s9);
    pub const S10_OFFSET: usize = core::mem::offset_of!(Context, s10);
    pub const S11_OFFSET: usize = core::mem::offset_of!(Context, s11);
    pub const RETURN_ADDRESS_OFFSET: usize = core::mem::offset_of!(Context, return_address);
    pub const STACK_POINTER_OFFSET: usize = core::mem::offset_of!(Context, stack_pointer);
    pub const IRQ_ENABLED_OFFSET: usize = core::mem::offset_of!(Context, irq_enabled);

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

/// Switches contexts while already returning through a trap or IRQ frame.
///
/// # Safety
///
/// `old` and `new` must satisfy the same requirements as [`switch_context`].
/// The caller must be on a trap or IRQ path whose final `sret` restores
/// interrupt state from the saved supervisor status.
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
    .type bullfinch_switch_context, @function
bullfinch_switch_context:
    sd s0, {s0_offset}(a0)
    sd s1, {s1_offset}(a0)
    sd s2, {s2_offset}(a0)
    sd s3, {s3_offset}(a0)
    sd s4, {s4_offset}(a0)
    sd s5, {s5_offset}(a0)
    sd s6, {s6_offset}(a0)
    sd s7, {s7_offset}(a0)
    sd s8, {s8_offset}(a0)
    sd s9, {s9_offset}(a0)
    sd s10, {s10_offset}(a0)
    sd s11, {s11_offset}(a0)
    sd ra, {return_address_offset}(a0)
    sd sp, {stack_pointer_offset}(a0)

    ld s0, {s0_offset}(a1)
    ld s1, {s1_offset}(a1)
    ld s2, {s2_offset}(a1)
    ld s3, {s3_offset}(a1)
    ld s4, {s4_offset}(a1)
    ld s5, {s5_offset}(a1)
    ld s6, {s6_offset}(a1)
    ld s7, {s7_offset}(a1)
    ld s8, {s8_offset}(a1)
    ld s9, {s9_offset}(a1)
    ld s10, {s10_offset}(a1)
    ld s11, {s11_offset}(a1)
    ld ra, {return_address_offset}(a1)
    ld sp, {stack_pointer_offset}(a1)

    ld t0, {irq_enabled_offset}(a1)
    beqz t0, 1f
    csrsi sstatus, 0x2
    j 2f
1:
    csrci sstatus, 0x2
2:
    ret

    .global bullfinch_switch_context_from_trap
    .type bullfinch_switch_context_from_trap, @function
bullfinch_switch_context_from_trap:
    sd s0, {s0_offset}(a0)
    sd s1, {s1_offset}(a0)
    sd s2, {s2_offset}(a0)
    sd s3, {s3_offset}(a0)
    sd s4, {s4_offset}(a0)
    sd s5, {s5_offset}(a0)
    sd s6, {s6_offset}(a0)
    sd s7, {s7_offset}(a0)
    sd s8, {s8_offset}(a0)
    sd s9, {s9_offset}(a0)
    sd s10, {s10_offset}(a0)
    sd s11, {s11_offset}(a0)
    sd ra, {return_address_offset}(a0)
    sd sp, {stack_pointer_offset}(a0)

    ld s0, {s0_offset}(a1)
    ld s1, {s1_offset}(a1)
    ld s2, {s2_offset}(a1)
    ld s3, {s3_offset}(a1)
    ld s4, {s4_offset}(a1)
    ld s5, {s5_offset}(a1)
    ld s6, {s6_offset}(a1)
    ld s7, {s7_offset}(a1)
    ld s8, {s8_offset}(a1)
    ld s9, {s9_offset}(a1)
    ld s10, {s10_offset}(a1)
    ld s11, {s11_offset}(a1)
    ld ra, {return_address_offset}(a1)
    ld sp, {stack_pointer_offset}(a1)
    ret

    .global bullfinch_thread_trampoline
    .type bullfinch_thread_trampoline, @function
bullfinch_thread_trampoline:
    mv a0, s2
    jr s1
"#
    ,
    s0_offset = const Context::S0_OFFSET,
    s1_offset = const Context::S1_OFFSET,
    s2_offset = const Context::S2_OFFSET,
    s3_offset = const Context::S3_OFFSET,
    s4_offset = const Context::S4_OFFSET,
    s5_offset = const Context::S5_OFFSET,
    s6_offset = const Context::S6_OFFSET,
    s7_offset = const Context::S7_OFFSET,
    s8_offset = const Context::S8_OFFSET,
    s9_offset = const Context::S9_OFFSET,
    s10_offset = const Context::S10_OFFSET,
    s11_offset = const Context::S11_OFFSET,
    return_address_offset = const Context::RETURN_ADDRESS_OFFSET,
    stack_pointer_offset = const Context::STACK_POINTER_OFFSET,
    irq_enabled_offset = const Context::IRQ_ENABLED_OFFSET,
);

const _: () = assert!(core::mem::size_of::<Context>() == Context::SIZE);
const _: () = assert!(core::mem::align_of::<Context>() == 16);
const _: () = assert!(Context::S0_OFFSET == 0);
const _: () = assert!(Context::S1_OFFSET == 8);
const _: () = assert!(Context::S11_OFFSET == 88);
const _: () = assert!(Context::RETURN_ADDRESS_OFFSET == 96);
const _: () = assert!(Context::STACK_POINTER_OFFSET == 104);
const _: () = assert!(Context::IRQ_ENABLED_OFFSET == 112);

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
