//! ARM64 FP/SIMD controls.
//!
//! The `aarch64-unknown-none-softfloat` target keeps compiled kernel code from
//! using FP/SIMD registers. Trap entry disables access but leaves the user's
//! values in the registers. A thread switch saves the outgoing thread's state
//! and restores the incoming thread's state. Returning to the same thread only
//! re-enables access, avoiding a save and restore on every trap.
//!
//! While the kernel runs, CPACR_EL1 traps FP/SIMD access at both EL0 and EL1.
//! Accidental kernel FP use therefore faults instead of changing user state.

use core::{
    arch::{asm, global_asm},
    cell::UnsafeCell,
};

use kernel::fp::{ThreadFpState, UserFpState};

const CPACR_EL1_FPEN_SHIFT: usize = 20;
const CPACR_EL1_FPEN_MASK: usize = 0b11 << CPACR_EL1_FPEN_SHIFT;
const CPACR_EL1_FPEN_ALL_TRAPPED: usize = 0b00 << CPACR_EL1_FPEN_SHIFT;
const CPACR_EL1_FPEN_ENABLED: usize = 0b11 << CPACR_EL1_FPEN_SHIFT;
const CPACR_EL1_ZEN_MASK: usize = 0b11 << 16;
const CPACR_EL1_SMEN_MASK: usize = 0b11 << 24;
const CPACR_EL1_UNSUPPORTED_VECTOR_MASK: usize = CPACR_EL1_ZEN_MASK | CPACR_EL1_SMEN_MASK;

/// FPEN=00 traps FP/SIMD at both EL0 and EL1. Trap entry installs this value
/// without saving the resident user registers. This makes accidental kernel
/// FP/SIMD use fault. A thread switch temporarily enables access to transfer
/// the register state between owners.
pub const CPACR_EL1_KERNEL: usize = CPACR_EL1_FPEN_ALL_TRAPPED;
/// FPEN=11 is the only encoding that permits EL0 FP/SIMD access. It also permits
/// EL1 access, which the kernel uses only for explicit state transfers.
/// Trap exit installs this value for an enabled EL0 thread. The next trap
/// entry disables EL1 access before running Rust code.
pub const CPACR_EL1_USER_FP_ENABLED: usize = CPACR_EL1_FPEN_ENABLED;

#[repr(C, align(16))]
pub struct TrapFpScratch {
    return_enabled: UnsafeCell<u8>,
}

// SAFETY: ARM64 boot parks secondary CPUs, so current trap handling is UP.
// Trap entry records whether the interrupted user context owned the resident
// register file, and trap exit consumes it on the same CPU. TODO(smp): replace
// this with per-CPU scratch storage before secondary CPUs can enter EL0.
unsafe impl Sync for TrapFpScratch {}

impl TrapFpScratch {
    pub const RETURN_ENABLED_OFFSET: usize = core::mem::offset_of!(Self, return_enabled);

    const fn new() -> Self {
        Self {
            return_enabled: UnsafeCell::new(0),
        }
    }
}

pub(super) static A64_TRAP_FP_SCRATCH: TrapFpScratch = TrapFpScratch::new();

global_asm!(
    r#"
    .arch armv8-a+fp+simd
    .text
    .macro a64_store_fp_state base, tmp_x, tmp_w
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

    .macro a64_load_fp_state base, tmp_x, tmp_w
    ldp q0, q1, [\base, #(16 * 0)]
    ldp q2, q3, [\base, #(16 * 2)]
    ldp q4, q5, [\base, #(16 * 4)]
    ldp q6, q7, [\base, #(16 * 6)]
    ldp q8, q9, [\base, #(16 * 8)]
    ldp q10, q11, [\base, #(16 * 10)]
    ldp q12, q13, [\base, #(16 * 12)]
    ldp q14, q15, [\base, #(16 * 14)]
    ldp q16, q17, [\base, #(16 * 16)]
    ldp q18, q19, [\base, #(16 * 18)]
    ldp q20, q21, [\base, #(16 * 20)]
    ldp q22, q23, [\base, #(16 * 22)]
    ldp q24, q25, [\base, #(16 * 24)]
    ldp q26, q27, [\base, #(16 * 26)]
    ldp q28, q29, [\base, #(16 * 28)]
    ldp q30, q31, [\base, #(16 * 30)]
    ldr \tmp_w, [\base, #{fpsr_offset}]
    msr fpsr, \tmp_x
    ldr \tmp_w, [\base, #{fpcr_offset}]
    msr fpcr, \tmp_x
    .endm

    .global a64_fp_save
    .type a64_fp_save, %function
a64_fp_save:
    a64_store_fp_state x0, x1, w1
    ret

    .global a64_fp_restore
    .type a64_fp_restore, %function
a64_fp_restore:
    a64_load_fp_state x0, x1, w1
    ret

    .purgem a64_store_fp_state
    .purgem a64_load_fp_state
    "#,
    fpsr_offset = const UserFpState::FPSR_OFFSET,
    fpcr_offset = const UserFpState::FPCR_OFFSET,
);

unsafe extern "C" {
    fn a64_fp_save(state: *mut UserFpState);
    pub(super) fn a64_fp_restore(state: *const UserFpState);
}

pub fn disable_fp_simd() {
    let next = (read_cpacr_el1() & !(CPACR_EL1_FPEN_MASK | CPACR_EL1_UNSUPPORTED_VECTOR_MASK))
        | CPACR_EL1_KERNEL;
    write_cpacr_el1(next);
}

pub fn enable_user_fp_simd() {
    let next = (read_cpacr_el1() & !CPACR_EL1_UNSUPPORTED_VECTOR_MASK) | CPACR_EL1_USER_FP_ENABLED;
    write_cpacr_el1(next);
}

pub fn activate_user_state(thread: &ThreadFpState) {
    let state = thread
        .user_state()
        .expect("enabled ARM64 FP state must have a saved image");
    enable_user_fp_simd();
    // SAFETY: First-use handling owns the current CPU register file and will
    // return to this same thread after access is disabled for the kernel again.
    unsafe { restore_current_state(state) };
    disable_fp_simd();
    set_return_enabled(true);
}

/// Transfers the resident FP/SIMD register file at a scheduler context switch.
///
/// # Safety
///
/// Trap entry must have recorded the outgoing user access state and disabled
/// FP/SIMD. `old` and `new` must be the scheduler's actual switch pair.
pub unsafe fn context_switch(old: &mut ThreadFpState, new: &ThreadFpState) {
    let old_is_resident = return_enabled();
    debug_assert_eq!(old_is_resident, old.user_enabled());
    let new_state = if new.user_enabled() {
        Some(
            new.user_state()
                .expect("enabled ARM64 FP state must have a saved image"),
        )
    } else {
        None
    };

    if old_is_resident || new_state.is_some() {
        enable_user_fp_simd();
    }
    if old_is_resident {
        old.save_user_state_with(|state| {
            // SAFETY: The outgoing thread owns the resident register file and
            // FP/SIMD access was enabled immediately above.
            unsafe { save_current_state(state) };
        });
    }
    if let Some(state) = new_state {
        // SAFETY: The scheduler selected `new`, and FP/SIMD access is enabled
        // only for this restore window before the integer context switch.
        unsafe { restore_current_state(state) };
    }
    disable_fp_simd();
    set_return_enabled(new_state.is_some());
}

/// Saves the current CPU FP/SIMD register file into `state`.
///
/// # Safety
///
/// The caller must enable EL1 FP/SIMD access before this call and own the live
/// FP/SIMD state. If access is trapped, this function faults.
pub unsafe fn save_current_state(state: &mut UserFpState) {
    // SAFETY: The caller proves FP/SIMD access and state ownership.
    unsafe { a64_fp_save(state) };
}

/// Restores the current CPU FP/SIMD register file from `state`.
///
/// # Safety
///
/// The caller must enable EL1 FP/SIMD access before this call. The restored
/// state must belong to the execution context that will next use FP/SIMD.
pub unsafe fn restore_current_state(state: &UserFpState) {
    // SAFETY: The caller proves FP/SIMD access and state ownership.
    unsafe { a64_fp_restore(state) };
}

fn return_enabled() -> bool {
    // SAFETY: Trap entry is the single producer and the current trap handler is
    // the single consumer while secondary CPUs remain parked.
    unsafe { *A64_TRAP_FP_SCRATCH.return_enabled.get() != 0 }
}

fn set_return_enabled(enabled: bool) {
    // SAFETY: The current trap handler exclusively prepares this CPU's return
    // state while secondary CPUs remain parked.
    unsafe {
        *A64_TRAP_FP_SCRATCH.return_enabled.get() = u8::from(enabled);
    }
}

fn read_cpacr_el1() -> usize {
    let value: usize;
    // SAFETY: CPACR_EL1 is local CPU control state.
    unsafe {
        asm!("mrs {value}, cpacr_el1", value = out(reg) value, options(nomem, nostack, preserves_flags))
    };
    value
}

fn write_cpacr_el1(value: usize) {
    // SAFETY: CPACR_EL1 controls local CPU feature traps. ISB makes the new
    // access policy visible before later instructions execute.
    unsafe {
        asm!(
            "msr cpacr_el1, {value}",
            "isb",
            value = in(reg) value,
            options(nomem, nostack, preserves_flags)
        );
    }
}
