//! RISC-V trap vector installation.
//!
//! In vectored mode, interrupts enter at `base + 4 * cause`. Synchronous
//! exceptions enter at `base`. The table has 256 slots. Slot 5 takes the fast
//! timer path with a smaller register frame. Other slots use the full trap
//! entry path, where Rust decodes `scause`.
//! [`IrqFrame`] and [`TrapFrame`] define the layouts shared with this assembly.
//!
//! See RISC-V Privileged Specification, version 20250508, section 12.1.2 (stvec).

use core::arch::{asm, global_asm};

use kernel::trap::{
    cause::TrapKind,
    frame::riscv64::{IrqFrame, TrapFrame},
    report::TrapFrameSnapshot,
};

const STVEC_MODE_VECTORED: usize = 1;
const SSTATUS_SUPERVISOR_PREVIOUS_PRIVILEGE: usize = 1 << 8;
const SSTATUS_FS_SHIFT: usize = 13;
const SSTATUS_FS_MASK: usize = 0b11 << 13;
const FRAME_SIZE_NEGATIVE: isize = -(TrapFrame::SIZE as isize);
const IRQ_FRAME_SIZE_NEGATIVE: isize = -(IrqFrame::SIZE as isize);

global_asm!(
    r#"
    # The boot hart uses this stack only after an overflow.
    # TODO(smp): give each hart an overflow stack before starting secondary harts.
    .section .bss.stack_overflow, "aw"
    .balign 16
__bullfinch_riscv64_overflow_stack:
    .skip {overflow_stack_size}
__bullfinch_riscv64_overflow_stack_top:

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
    j rust_riscv64_kernel_fast_irq_entry

    # Slots 6-255 avoid short-table fallthrough for platform/local causes.
    .rept 250
    j rust_riscv64_kernel_trap_entry
    .endr
    .option pop

    .text
    # sscratch is reserved for trap entry. Interrupts stay masked,
    # and the check does not access memory.
    .macro check_kernel_stack frame_size
    csrw sscratch, t0
    li t0, {stack_region_base}
    sub t0, sp, t0
    srli t0, t0, {stack_region_shift}
    bnez t0, 99f

    slli t0, sp, {stack_slot_mask_shift}
    srli t0, t0, {stack_slot_mask_shift}
    addi t0, t0, -2048
    addi t0, t0, -2048
    addi t0, t0, -\frame_size
    bltz t0, .Lstack_overflow
    # Convert to SP-bottom-1 so the exact usable top is still accepted.
    addi t0, t0, (\frame_size - 1)
    srli t0, t0, {stack_size_shift}
    bnez t0, .Lstack_overflow
99:
    csrr t0, sscratch
    .endm

    # Only a trap from U-mode writes the scratch byte. A trap from S-mode does
    # not change the current thread, so writing here would lose the outer
    # record. See `TrapFpScratch`.
    .macro record_user_fp_status status, scratch, tmp
    andi \tmp, \status, {sstatus_spp}
    bnez \tmp, 98f
    li \tmp, {sstatus_fs_mask}
    and \tmp, \status, \tmp
    srli \tmp, \tmp, {sstatus_fs_shift}
    la \scratch, {trap_fp_scratch}
    sb \tmp, {scratch_return_status_offset}(\scratch)
98:
    li \scratch, {sstatus_fs_mask}
    csrc sstatus, \scratch
    not \scratch, \scratch
    and \status, \status, \scratch
    .endm

    # A return to S-mode leaves the scratch byte for the outer trap. A return
    # to U-mode consumes it.
    .macro restore_user_fp_status_for_return scratch, tmp, status, status_offset
    ld \status, \status_offset(sp)
    andi \scratch, \status, {sstatus_spp}
    bnez \scratch, 99f
    la \scratch, {trap_fp_scratch}
    lbu \status, {scratch_return_status_offset}(\scratch)
    sb zero, {scratch_return_status_offset}(\scratch)
    csrr \tmp, sstatus
    li \scratch, {sstatus_fs_mask}
    not \scratch, \scratch
    and \tmp, \tmp, \scratch
    slli \status, \status, {sstatus_fs_shift}
    or \tmp, \tmp, \status
    csrw sstatus, \tmp
99:
    .endm

    .global rust_riscv64_kernel_trap_entry
rust_riscv64_kernel_trap_entry:
    check_kernel_stack {frame_size}
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
    record_user_fp_status t0, t1, t2
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
    restore_user_fp_status_for_return t0, t1, t2, {status_offset}
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

    .global rust_riscv64_kernel_fast_irq_entry
rust_riscv64_kernel_fast_irq_entry:
    check_kernel_stack {irq_frame_size}
    addi sp, sp, {irq_frame_size_negative}
    sd ra, 0(sp)
    sd t0, 8(sp)
    sd t1, 16(sp)
    sd t2, 24(sp)
    sd a0, 32(sp)
    sd a1, 40(sp)
    sd a2, 48(sp)
    sd a3, 56(sp)
    sd a4, 64(sp)
    sd a5, 72(sp)
    sd a6, 80(sp)
    sd a7, 88(sp)
    sd t3, 96(sp)
    sd t4, 104(sp)
    sd t5, 112(sp)
    sd t6, 120(sp)
    csrr t0, sepc
    sd t0, {irq_program_counter_offset}(sp)
    csrr t0, sstatus
    record_user_fp_status t0, t1, t2
    sd t0, {irq_status_offset}(sp)
    call rust_riscv64_handle_kernel_fast_irq
    ld t0, {irq_program_counter_offset}(sp)
    csrw sepc, t0
    ld t0, {irq_status_offset}(sp)
    csrw sstatus, t0
    restore_user_fp_status_for_return t0, t1, t2, {irq_status_offset}
    ld ra, 0(sp)
    ld t0, 8(sp)
    ld t1, 16(sp)
    ld t2, 24(sp)
    ld a0, 32(sp)
    ld a1, 40(sp)
    ld a2, 48(sp)
    ld a3, 56(sp)
    ld a4, 64(sp)
    ld a5, 72(sp)
    ld a6, 80(sp)
    ld a7, 88(sp)
    ld t3, 96(sp)
    ld t4, 104(sp)
    ld t5, 112(sp)
    ld t6, 120(sp)
    addi sp, sp, {irq_frame_size}
    sret

.Lstack_overflow:
    csrci sstatus, 2
    # Direct mode sends every further trap to the stack-free halt path.
    la t0, .Loverflow_halt
    csrw stvec, t0
    la sp, __bullfinch_riscv64_overflow_stack_top
    li t0, {sstatus_fs_mask}
    csrc sstatus, t0
    tail {stack_overflow}
    .balign 4
.Loverflow_halt:
    csrci sstatus, 2
98:
    wfi
    j 98b

    .purgem check_kernel_stack
    .purgem record_user_fp_status
    .purgem restore_user_fp_status_for_return
    "#,
    sstatus_spp = const SSTATUS_SUPERVISOR_PREVIOUS_PRIVILEGE,
    sstatus_fs_shift = const SSTATUS_FS_SHIFT,
    sstatus_fs_mask = const SSTATUS_FS_MASK,
    frame_size_negative = const FRAME_SIZE_NEGATIVE,
    frame_size = const TrapFrame::SIZE,
    saved_stack_pointer_offset = const TrapFrame::SAVED_STACK_POINTER_OFFSET,
    program_counter_offset = const TrapFrame::PROGRAM_COUNTER_OFFSET,
    status_offset = const TrapFrame::STATUS_OFFSET,
    cause_offset = const TrapFrame::CAUSE_OFFSET,
    trap_value_offset = const TrapFrame::TRAP_VALUE_OFFSET,
    last_register_offset = const TrapFrame::LAST_REGISTER_OFFSET,
    irq_frame_size_negative = const IRQ_FRAME_SIZE_NEGATIVE,
    irq_frame_size = const IrqFrame::SIZE,
    irq_program_counter_offset = const IrqFrame::PROGRAM_COUNTER_OFFSET,
    irq_status_offset = const IrqFrame::STATUS_OFFSET,
    scratch_return_status_offset = const super::fp::TrapFpScratch::RETURN_STATUS_OFFSET,
    trap_fp_scratch = sym super::fp::RV64_TRAP_FP_SCRATCH,
    overflow_stack_size = const crate::runtime::trap::OVERFLOW_STACK_SIZE,
    stack_region_base = const super::mmu::kernel_stack_region_base().get(),
    stack_region_shift = const kernel::task::KERNEL_STACK_REGION_SIZE.ilog2(),
    stack_slot_mask_shift = const usize::BITS - kernel::task::KERNEL_STACK_SLOT_SIZE.ilog2(),
    stack_size_shift = const kernel::task::KERNEL_STACK_SIZE.ilog2(),
    stack_overflow = sym crate::runtime::trap::stack_overflow,
);

const _: () = assert!(kernel::task::KERNEL_STACK_GUARD_SIZE == 4096);
const _: () = assert!(kernel::task::KERNEL_STACK_SIZE.is_power_of_two());
const _: () = assert!(
    super::mmu::kernel_stack_region_base()
        .get()
        .is_multiple_of(kernel::task::KERNEL_STACK_SLOT_SIZE)
);

/// # Safety
/// The test must retain the target stack and its neighbor until the CPU halts.
#[cfg(feature = "stack-overflow-test")]
#[unsafe(naked)]
pub unsafe extern "C" fn trigger_stack_overflow_test(_stack_pointer: usize) -> ! {
    #[cfg(feature = "stack-overflow-irq-test")]
    core::arch::naked_asm!("mv sp, a0", "csrsi sstatus, 2", "2:", "wfi", "j 2b");
    #[cfg(not(feature = "stack-overflow-irq-test"))]
    core::arch::naked_asm!("mv sp, a0", "sd zero, 0(sp)", "2:", "wfi", "j 2b");
}

unsafe extern "C" {
    fn __bullfinch_riscv64_trap_vector();
}

pub fn init() {
    let vector_base = __bullfinch_riscv64_trap_vector as *const () as usize;
    let stvec = vector_base | STVEC_MODE_VECTORED;
    let installed: usize;

    // SAFETY: `vector_base` names the 1024-byte-aligned `.trap` table emitted
    // above. It covers causes 0-255 with either the full trap or fast timer
    // entry path. FENCE.I makes the trap code visible before traps are enabled.
    unsafe {
        asm!(
            "csrw stvec, {stvec}",
            "csrr {installed}, stvec",
            "fence.i",
            stvec = in(reg) stvec,
            installed = lateout(reg) installed,
            options(nostack, preserves_flags)
        );
    }
    assert_eq!(installed, stvec, "riscv64: stvec rejected trap table");
}

const _: () = assert!(TrapFrame::SIZE == 288);
const _: () = assert!(IrqFrame::SIZE == 144);

#[unsafe(no_mangle)]
extern "C" fn rust_riscv64_handle_kernel_trap(frame: *mut TrapFrame) {
    // SAFETY: Assembly passes a complete `TrapFrame` on the current stack. This
    // trap owns the frame for its full lifetime. Null reaches the halt path
    // without a bad dereference.
    if let Some(frame) = unsafe { frame.as_mut() } {
        if TrapFrameSnapshot::cause(frame).is_interrupt() {
            crate::runtime::trap::handle_kernel_interrupt(frame);
        } else {
            if is_user_fp_unavailable(frame) {
                enable_current_user_fp_restore();
                return;
            }

            crate::runtime::trap::handle_kernel_trap(frame);
        }
        return;
    }

    crate::console::print_unsafe("\n[TRAP:riscv64]\nmissing trap frame\n");
    crate::hal::cpu::halt()
}

#[unsafe(no_mangle)]
extern "C" fn rust_riscv64_handle_kernel_fast_irq() {
    crate::runtime::trap::handle_fast_interrupt();
}

fn enable_current_user_fp_restore() {
    kernel::task::enable_current_user_fp_state(super::fp::activate_user_state)
        .expect("U-mode FP trap implies a current thread");
}

fn is_user_fp_unavailable(frame: &TrapFrame) -> bool {
    // RISC-V reports FP access with sstatus.FS=Off as an illegal instruction.
    if !frame.is_from_user()
        || !matches!(
            TrapFrameSnapshot::cause(frame).kind(),
            TrapKind::IllegalInstruction
        )
    {
        return false;
    }

    let stored_status = kernel::task::with_current_user_fp_state(kernel::fp::ThreadFpState::status)
        .expect("U-mode FP trap implies a current thread");
    kernel::fp::illegal_instruction_may_be_first_fp_use(frame.fault_addr(), stored_status)
}
