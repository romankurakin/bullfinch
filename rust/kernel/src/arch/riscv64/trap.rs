//! RISC-V trap vector installation.
//!
//! In vectored mode `stvec` jumps to `base + 4 * cause`. The table has 256
//! slots and routes all of them through the common dispatcher. Assembly only
//! saves registers; Rust validates `scause`.
//!
//! See RISC-V Privileged Specification, section 4.1.5 (stvec).

use core::arch::{asm, global_asm};

use kernel::trap::{frame::riscv64::TrapFrame, report::TrapFrameSnapshot};

const STVEC_MODE_VECTORED: usize = 1;
const FRAME_SIZE_NEGATIVE: isize = -(TrapFrame::SIZE as isize);

global_asm!(
    r#"
    .section .trap, "ax"
    .balign 1024
    .global __bullfinch_riscv64_trap_vector
__bullfinch_riscv64_trap_vector:
    .option push
    .option norvc
    # In vectored mode, interrupts enter at base + 4 * cause. Slot 0 handles
    # synchronous exceptions. Other slots keep scause validation in Rust.
    j rust_riscv64_kernel_trap_entry

    # Slots 1-4 are reserved or unused for now.
    .rept 4
    j rust_riscv64_kernel_trap_entry
    .endr

    # Slot 5 is the supervisor timer interrupt.
    j rust_riscv64_kernel_trap_entry

    # Slots 6-255 avoid short-table fallthrough for platform/local causes.
    .rept 250
    j rust_riscv64_kernel_trap_entry
    .endr
    .option pop

    .text
    .global rust_riscv64_kernel_trap_entry
rust_riscv64_kernel_trap_entry:
    addi sp, sp, {frame_size_negative}
    sd x1, 0(sp)
    sd x2, 8(sp)
    sd x3, 16(sp)
    sd x4, 24(sp)
    sd x5, 32(sp)
    sd x6, 40(sp)
    sd x7, 48(sp)
    sd x8, 56(sp)
    sd x9, 64(sp)
    sd x10, 72(sp)
    sd x11, 80(sp)
    sd x12, 88(sp)
    sd x13, 96(sp)
    sd x14, 104(sp)
    sd x15, 112(sp)
    sd x16, 120(sp)
    sd x17, 128(sp)
    sd x18, 136(sp)
    sd x19, 144(sp)
    sd x20, 152(sp)
    sd x21, 160(sp)
    sd x22, 168(sp)
    sd x23, 176(sp)
    sd x24, 184(sp)
    sd x25, 192(sp)
    sd x26, 200(sp)
    sd x27, 208(sp)
    sd x28, 216(sp)
    sd x29, 224(sp)
    sd x30, 232(sp)
    sd x31, 240(sp)
    addi t0, sp, {frame_size}
    sd t0, {saved_stack_pointer_offset}(sp)
    csrr t0, sepc
    sd t0, {program_counter_offset}(sp)
    csrr t0, sstatus
    sd t0, {status_offset}(sp)
    csrr t0, scause
    sd t0, {cause_offset}(sp)
    csrr t0, stval
    sd t0, {trap_value_offset}(sp)
    mv a0, sp
    call rust_riscv64_handle_kernel_trap
    ld t0, {program_counter_offset}(sp)
    csrw sepc, t0
    ld t0, {status_offset}(sp)
    csrw sstatus, t0
    ld x1, 0(sp)
    ld x3, 16(sp)
    ld x4, 24(sp)
    ld x6, 40(sp)
    ld x7, 48(sp)
    ld x8, 56(sp)
    ld x9, 64(sp)
    ld x10, 72(sp)
    ld x11, 80(sp)
    ld x12, 88(sp)
    ld x13, 96(sp)
    ld x14, 104(sp)
    ld x15, 112(sp)
    ld x16, 120(sp)
    ld x17, 128(sp)
    ld x18, 136(sp)
    ld x19, 144(sp)
    ld x20, 152(sp)
    ld x21, 160(sp)
    ld x22, 168(sp)
    ld x23, 176(sp)
    ld x24, 184(sp)
    ld x25, 192(sp)
    ld x26, 200(sp)
    ld x27, 208(sp)
    ld x28, 216(sp)
    ld x29, 224(sp)
    ld x30, 232(sp)
    ld x31, {last_register_offset}(sp)
    ld x5, 32(sp)
    addi sp, sp, {frame_size}
    sret
    "#,
    frame_size_negative = const FRAME_SIZE_NEGATIVE,
    frame_size = const TrapFrame::SIZE,
    saved_stack_pointer_offset = const TrapFrame::SAVED_STACK_POINTER_OFFSET,
    program_counter_offset = const TrapFrame::PROGRAM_COUNTER_OFFSET,
    status_offset = const TrapFrame::STATUS_OFFSET,
    cause_offset = const TrapFrame::CAUSE_OFFSET,
    trap_value_offset = const TrapFrame::TRAP_VALUE_OFFSET,
    last_register_offset = const TrapFrame::LAST_REGISTER_OFFSET,
);

unsafe extern "C" {
    fn __bullfinch_riscv64_trap_vector();
}

pub fn init() {
    let vector_base = __bullfinch_riscv64_trap_vector as *const () as usize;
    let stvec = vector_base | STVEC_MODE_VECTORED;

    // SAFETY: `vector_base` names the 1024-byte-aligned `.trap` table emitted
    // above. It covers causes 0-255, and every slot routes through the common
    // dispatcher. FENCE.I makes the trap code visible before traps are enabled.
    unsafe {
        asm!(
            "csrw stvec, {stvec}",
            "fence.i",
            stvec = in(reg) stvec,
            options(nostack, preserves_flags)
        );
    }
}

const _: () = assert!(TrapFrame::SIZE == 288);

#[unsafe(no_mangle)]
extern "C" fn rust_riscv64_handle_kernel_trap(frame: *mut TrapFrame) {
    // SAFETY: Assembly passes a complete `TrapFrame` on the current stack. This
    // trap owns the frame for its full lifetime. Null reaches the halt path
    // without a bad dereference.
    if let Some(frame) = unsafe { frame.as_mut() } {
        if TrapFrameSnapshot::cause(frame).is_interrupt() {
            crate::runtime::trap::handle_kernel_interrupt(frame);
        } else {
            crate::runtime::trap::handle_kernel_trap(frame);
        }
        return;
    }

    crate::console::print_unsafe("\n[TRAP:riscv64]\nmissing trap frame\n");
    crate::hal::cpu::halt()
}
