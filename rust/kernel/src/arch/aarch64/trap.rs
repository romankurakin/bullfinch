//! ARM64 trap vector installation.
//!
//! ARM64 requires VBAR_EL1 to point at a 2 KiB-aligned table with 16 entries
//! of 128 bytes each. Only two slots matter for now (synchronous exception and
//! IRQ from current EL). The rest branch to the same handlers so that an
//! unexpected trap type reaches the common panic path.
//!
//! See ARM Architecture Reference Manual, D1.9 (Vector tables).

use core::arch::{asm, global_asm};

use kernel::trap::frame::arm64::{IrqFrame, TrapFrame};

global_asm!(
    r#"
    .section .vectors, "ax"
    .balign 2048
    .global __bullfinch_aarch64_trap_vectors
__bullfinch_aarch64_trap_vectors:
    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_irq_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128

    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_irq_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128

    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_irq_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128

    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_irq_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128
    b rust_aarch64_kernel_trap_entry
    .balign 128

    .text
    .macro trap_store_fp_state base, tmp_x, tmp_w
    stp q0, q1, [\base, #(16 * 0)]
    stp q2, q3, [\base, #(16 * 2)]
    stp q4, q5, [\base, #(16 * 4)]
    stp q6, q7, [\base, #(16 * 6)]
    stp q8, q9, [\base, #(16 * 8)]
    stp q10, q11, [\base, #(16 * 10)]
    stp q12, q13, [\base, #(16 * 12)]
    stp q14, q15, [\base, #(16 * 14)]
    stp q16, q17, [\base, #(16 * 16)]
    stp q18, q19, [\base, #(16 * 18)]
    stp q20, q21, [\base, #(16 * 20)]
    stp q22, q23, [\base, #(16 * 22)]
    stp q24, q25, [\base, #(16 * 24)]
    stp q26, q27, [\base, #(16 * 26)]
    stp q28, q29, [\base, #(16 * 28)]
    stp q30, q31, [\base, #(16 * 30)]
    mrs \tmp_x, fpsr
    str \tmp_w, [\base, #{fpsr_offset}]
    mrs \tmp_x, fpcr
    str \tmp_w, [\base, #{fpcr_offset}]
    .endm

    .macro save_user_fp_state_if_enabled
    mrs x16, spsr_el1
    and x16, x16, #0xf
    cbnz x16, 99f
    mrs x16, cpacr_el1
    and x16, x16, #{fp_enabled_mask}
    cmp x16, #{user_fp_enabled}
    b.ne 99f
    adrp x16, {trap_fp_scratch}
    add x16, x16, :lo12:{trap_fp_scratch}
    add x16, x16, #{scratch_state_offset}
    trap_store_fp_state x16, x17, w17
    mov x17, #1
    strb w17, [x16, #{scratch_saved_relative_offset}]
99:
    .endm

    .macro save_trap_frame handler
    sub sp, sp, #{frame_size}
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    save_user_fp_state_if_enabled
    mov x16, #{kernel_cpacr}
    msr cpacr_el1, x16
    isb
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    add x0, sp, #{frame_size}
    stp x30, x0, [sp, #{link_register_offset}]
    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #{exception_return_address_offset}]
    mrs x0, esr_el1
    mrs x1, far_el1
    stp x0, x1, [sp, #{syndrome_offset}]
    mov x0, sp
    bl \handler
    ldp x0, x1, [sp, #{exception_return_address_offset}]
    msr elr_el1, x0
    msr spsr_el1, x1
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #{link_register_offset}]
    ldp x0, x1, [sp, #0]
    add sp, sp, #{frame_size}
    eret
    .endm

    .macro save_irq_frame handler
    sub sp, sp, #{irq_frame_size}
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    save_user_fp_state_if_enabled
    mov x16, #{kernel_cpacr}
    msr cpacr_el1, x16
    isb
    stp x18, x30, [sp, #144]
    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #{irq_exception_return_address_offset}]
    bl \handler
    ldp x0, x1, [sp, #{irq_exception_return_address_offset}]
    msr elr_el1, x0
    msr spsr_el1, x1
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x30, [sp, #144]
    ldp x0, x1, [sp, #0]
    add sp, sp, #{irq_frame_size}
    eret
    .endm

    .global rust_aarch64_kernel_trap_entry
rust_aarch64_kernel_trap_entry:
    save_trap_frame rust_aarch64_handle_kernel_trap

    .global rust_aarch64_kernel_irq_entry
rust_aarch64_kernel_irq_entry:
    save_irq_frame rust_aarch64_handle_kernel_irq
    .purgem trap_store_fp_state
    .purgem save_user_fp_state_if_enabled
    .purgem save_trap_frame
    .purgem save_irq_frame
    "#,
    frame_size = const TrapFrame::SIZE,
    link_register_offset = const TrapFrame::LINK_REGISTER_OFFSET,
    exception_return_address_offset = const TrapFrame::EXCEPTION_RETURN_ADDRESS_OFFSET,
    syndrome_offset = const TrapFrame::SYNDROME_OFFSET,
    irq_frame_size = const IrqFrame::SIZE,
    irq_exception_return_address_offset = const IrqFrame::EXCEPTION_RETURN_ADDRESS_OFFSET,
    fp_enabled_mask = const super::fp::CPACR_EL1_USER_FP_ENABLED,
    user_fp_enabled = const super::fp::CPACR_EL1_USER_FP_ENABLED,
    kernel_cpacr = const super::fp::CPACR_EL1_KERNEL,
    scratch_state_offset = const super::fp::TrapFpScratch::STATE_OFFSET,
    scratch_saved_relative_offset = const super::fp::TrapFpScratch::SAVED_FROM_STATE_OFFSET,
    fpsr_offset = const kernel::fp::UserFpState::FPSR_OFFSET,
    fpcr_offset = const kernel::fp::UserFpState::FPCR_OFFSET,
    trap_fp_scratch = sym super::fp::A64_TRAP_FP_SCRATCH,
);

unsafe extern "C" {
    fn __bullfinch_aarch64_trap_vectors();
}

pub fn init() {
    let vector_base = __bullfinch_aarch64_trap_vectors as *const () as usize;

    // SAFETY: `vector_base` names the 2 KiB-aligned `.vectors` table. VBAR_EL1
    // is local CPU state. ISB makes the new vector base visible.
    unsafe {
        asm!(
            "msr vbar_el1, {vector_base}",
            "isb",
            vector_base = in(reg) vector_base,
            options(nostack, preserves_flags)
        );
    }
}

const _: () = assert!(TrapFrame::SIZE == 288);
const _: () = assert!(IrqFrame::SIZE == 176);

#[unsafe(no_mangle)]
extern "C" fn rust_aarch64_handle_kernel_trap(frame: *mut TrapFrame) {
    commit_trapped_user_fp_state();
    // SAFETY: Assembly passes a complete `TrapFrame` on the current stack. This
    // trap owns the frame for its full lifetime. Null reaches the halt path
    // without a bad dereference.
    if let Some(frame) = unsafe { frame.as_mut() } {
        crate::runtime::trap::handle_kernel_trap(frame);
        return;
    }

    crate::console::print_unsafe("\n[TRAP:arm64]\nmissing trap frame\n");
    crate::hal::cpu::halt()
}

#[unsafe(no_mangle)]
extern "C" fn rust_aarch64_handle_kernel_irq() {
    commit_trapped_user_fp_state();
    crate::runtime::trap::handle_fast_interrupt();
}

fn commit_trapped_user_fp_state() {
    if let Some(state) = super::fp::take_trapped_user_state() {
        kernel::task::save_current_user_fp_state(state)
            .expect("EL0 FP/SIMD trap implies a current thread");
    }
}
