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
    "#,
    frame_size = const TrapFrame::SIZE,
    link_register_offset = const TrapFrame::LINK_REGISTER_OFFSET,
    exception_return_address_offset = const TrapFrame::EXCEPTION_RETURN_ADDRESS_OFFSET,
    syndrome_offset = const TrapFrame::SYNDROME_OFFSET,
    irq_frame_size = const IrqFrame::SIZE,
    irq_exception_return_address_offset = const IrqFrame::EXCEPTION_RETURN_ADDRESS_OFFSET,
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
    crate::runtime::trap::handle_fast_interrupt();
}
