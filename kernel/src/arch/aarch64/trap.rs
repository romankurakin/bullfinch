//! ARM64 trap vector installation.
//!
//! ARM64 requires VBAR_EL1 to point at a 2 KiB-aligned table with 16 entries
//! of 128 bytes each. IRQ slots use a fast entry path with a smaller register
//! frame. All other slots use the full trap entry path for cause decoding and
//! diagnostics. The Rust handler handles user FP activation before passing
//! other exceptions to the common trap policy.
//! [`IrqFrame`] and [`TrapFrame`] define the layouts shared with this assembly.
//!
//! See ARM Architecture Reference Manual, D1.9 (Vector tables).

use core::arch::{asm, global_asm};

use kernel::trap::{
    cause::TrapKind,
    frame::arm64::{IrqFrame, TrapFrame},
    report::TrapFrameSnapshot,
};

global_asm!(
    r#"
    // The boot CPU uses this stack only after an overflow.
    // TODO(smp): give each CPU an overflow stack before starting secondary CPUs.
    .section .bss.stack_overflow, "aw"
    .balign 16
__bullfinch_aarch64_overflow_stack:
    .skip {overflow_stack_size}
__bullfinch_aarch64_overflow_stack_top:

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

    // After overflow, any further exception must halt without using a stack.
    .balign 2048
__bullfinch_aarch64_overflow_vectors:
    .rept 16
    b .Loverflow_halt
    .balign 128
    .endr

    .text
    // TPIDR_EL1 and TPIDRRO_EL0 are reserved for entry scratch.
    // Exceptions stay masked, and the check does not access memory.
    .macro check_kernel_stack frame_size
    msr tpidr_el1, x16
    msr tpidrro_el0, x17

    mov x16, sp
    mov x17, #{stack_region_base}
    sub x16, x16, x17
    lsr x17, x16, #{stack_region_shift}
    cbnz x17, 99f
    and x16, x16, #{stack_slot_mask}
    mov x17, #({stack_guard_size} + \frame_size)
    cmp x16, x17
    b.lo .Lstack_overflow
    mov x17, #{stack_top_offset}
    cmp x16, x17
    b.hi .Lstack_overflow
99:
    mrs x16, tpidr_el1
    mrs x17, tpidrro_el0
    .endm

    // Only a trap from EL0 writes the scratch byte. A trap from EL1 does not
    // change the current thread, so writing here would lose the outer record.
    // See `TrapFpScratch`.
    .macro record_user_fp_access
    mrs x16, spsr_el1
    and x16, x16, #0xf
    cbnz x16, 99f
    mrs x16, cpacr_el1
    and x16, x16, #{fp_enabled_mask}
    cmp x16, #{user_fp_enabled}
    cset w17, eq
    adrp x16, {trap_fp_scratch}
    add x16, x16, :lo12:{trap_fp_scratch}
    strb w17, [x16, #{scratch_return_enabled_offset}]
99:
    .endm

    // A return to EL1 leaves the scratch byte for the outer trap. A return
    // to EL0 consumes it.
    .macro restore_user_fp_access_for_return status_offset
    ldr x17, [sp, #\status_offset]
    and x17, x17, #0xf
    cbnz x17, 98f
    adrp x16, {trap_fp_scratch}
    add x16, x16, :lo12:{trap_fp_scratch}
    ldrb w17, [x16, #{scratch_return_enabled_offset}]
    strb wzr, [x16, #{scratch_return_enabled_offset}]
    cbz w17, 98f
    mov x17, #{user_fp_enabled}
    b 99f
98:
    mov x17, #{kernel_cpacr}
99:
    msr cpacr_el1, x17
    isb
    .endm

    .macro save_trap_frame handler
    check_kernel_stack {frame_size}
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
    record_user_fp_access
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
    restore_user_fp_access_for_return {program_status_offset}
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
    check_kernel_stack {irq_frame_size}
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
    record_user_fp_access
    mov x16, #{kernel_cpacr}
    msr cpacr_el1, x16
    isb
    stp x18, x30, [sp, #144]
    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #{irq_exception_return_address_offset}]
    bl \handler
    restore_user_fp_access_for_return {irq_program_status_offset}
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

.Lstack_overflow:
    msr daifset, #0xf
    adrp x16, __bullfinch_aarch64_overflow_vectors
    add x16, x16, :lo12:__bullfinch_aarch64_overflow_vectors
    msr vbar_el1, x16
    isb
    adrp x16, __bullfinch_aarch64_overflow_stack_top
    add x16, x16, :lo12:__bullfinch_aarch64_overflow_stack_top
    mov sp, x16
    mov x16, #{kernel_cpacr}
    msr cpacr_el1, x16
    isb
    b {stack_overflow}
.Loverflow_halt:
    msr daifset, #0xf
98:
    wfi
    b 98b

    .purgem check_kernel_stack
    .purgem record_user_fp_access
    .purgem restore_user_fp_access_for_return
    .purgem save_trap_frame
    .purgem save_irq_frame
    "#,
    frame_size = const TrapFrame::SIZE,
    link_register_offset = const TrapFrame::LINK_REGISTER_OFFSET,
    exception_return_address_offset = const TrapFrame::EXCEPTION_RETURN_ADDRESS_OFFSET,
    program_status_offset = const TrapFrame::PROGRAM_STATUS_OFFSET,
    syndrome_offset = const TrapFrame::SYNDROME_OFFSET,
    irq_frame_size = const IrqFrame::SIZE,
    irq_exception_return_address_offset = const IrqFrame::EXCEPTION_RETURN_ADDRESS_OFFSET,
    irq_program_status_offset = const IrqFrame::PROGRAM_STATUS_OFFSET,
    fp_enabled_mask = const super::fp::CPACR_EL1_USER_FP_ENABLED,
    user_fp_enabled = const super::fp::CPACR_EL1_USER_FP_ENABLED,
    kernel_cpacr = const super::fp::CPACR_EL1_KERNEL,
    scratch_return_enabled_offset = const super::fp::TrapFpScratch::RETURN_ENABLED_OFFSET,
    trap_fp_scratch = sym super::fp::A64_TRAP_FP_SCRATCH,
    overflow_stack_size = const crate::runtime::trap::OVERFLOW_STACK_SIZE,
    stack_region_base = const super::mmu::kernel_stack_region_base().get(),
    stack_region_shift = const kernel::task::KERNEL_STACK_REGION_SIZE.ilog2(),
    stack_slot_mask = const kernel::task::KERNEL_STACK_SLOT_SIZE - 1,
    stack_top_offset = const kernel::task::KERNEL_STACK_GUARD_SIZE + kernel::task::KERNEL_STACK_SIZE,
    stack_guard_size = const kernel::task::KERNEL_STACK_GUARD_SIZE,
    stack_overflow = sym crate::runtime::trap::stack_overflow,
);

/// # Safety
/// The test must retain the target stack and its neighbor until the CPU halts.
#[cfg(feature = "stack-overflow-test")]
#[unsafe(naked)]
pub unsafe extern "C" fn trigger_stack_overflow_test(_stack_pointer: usize) -> ! {
    #[cfg(feature = "stack-overflow-irq-test")]
    core::arch::naked_asm!("mov sp, x0", "msr daifclr, #2", "2:", "wfi", "b 2b");
    #[cfg(not(feature = "stack-overflow-irq-test"))]
    core::arch::naked_asm!("mov sp, x0", "str xzr, [sp]", "2:", "wfi", "b 2b");
}

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
        if is_user_fp_unavailable(frame) {
            enable_current_user_fp_restore();
            return;
        }

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

fn enable_current_user_fp_restore() {
    kernel::task::enable_current_user_fp_state(super::fp::activate_user_state)
        .expect("EL0 FP/SIMD trap implies a current thread");
}

fn is_user_fp_unavailable(frame: &TrapFrame) -> bool {
    let first_use = frame.is_from_user()
        && matches!(
            TrapFrameSnapshot::cause(frame).kind(),
            TrapKind::FloatingPointUnavailable
        );
    if !first_use {
        return false;
    }

    kernel::task::with_current_user_fp_state(|stored| !stored.user_enabled())
        .expect("EL0 FP/SIMD trap implies a current thread")
}
