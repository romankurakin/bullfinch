//! ARM64 FP/SIMD controls.
//!
//! The normal AArch64 target may emit FP/SIMD in EL1. User FP/SIMD state is
//! protected at exception and context-switch boundaries.

#![allow(
    dead_code,
    reason = "Rung 9 wires state helpers before full user return paths consume them"
)]

use core::{
    arch::{asm, global_asm},
    cell::UnsafeCell,
};

use kernel::fp::UserFpState;

const CPACR_EL1_FPEN_SHIFT: usize = 20;
const CPACR_EL1_FPEN_MASK: usize = 0b11 << CPACR_EL1_FPEN_SHIFT;
const CPACR_EL1_FPEN_EL0_TRAPPED: usize = 0b01 << CPACR_EL1_FPEN_SHIFT;
const CPACR_EL1_FPEN_ENABLED: usize = 0b11 << CPACR_EL1_FPEN_SHIFT;
const CPACR_EL1_ZEN_MASK: usize = 0b11 << 16;
const CPACR_EL1_SMEN_MASK: usize = 0b11 << 24;
const CPACR_EL1_UNSUPPORTED_VECTOR_MASK: usize = CPACR_EL1_ZEN_MASK | CPACR_EL1_SMEN_MASK;

pub const CPACR_EL1_KERNEL: usize = CPACR_EL1_FPEN_EL0_TRAPPED;
pub const CPACR_EL1_USER_FP_ENABLED: usize = CPACR_EL1_FPEN_ENABLED;

#[repr(C, align(16))]
pub struct TrapFpScratch {
    state: UnsafeCell<UserFpState>,
    saved: UnsafeCell<u8>,
}

// SAFETY: ARM64 boot parks secondary CPUs, so current trap handling is UP.
// Trap entry writes this scratch area before Rust runs, and Rust drains it on
// the same CPU before normal trap handling continues. TODO(smp): replace this
// with per-CPU scratch storage before secondary CPUs can enter EL0.
unsafe impl Sync for TrapFpScratch {}

impl TrapFpScratch {
    pub const STATE_OFFSET: usize = core::mem::offset_of!(Self, state);
    pub const SAVED_OFFSET: usize = core::mem::offset_of!(Self, saved);
    pub const SAVED_FROM_STATE_OFFSET: usize = Self::SAVED_OFFSET - Self::STATE_OFFSET;

    const fn new() -> Self {
        Self {
            state: UnsafeCell::new(UserFpState::zeroed()),
            saved: UnsafeCell::new(0),
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
    fn a64_fp_restore(state: *const UserFpState);
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

/// Saves the current CPU FP/SIMD register file into `state`.
///
/// # Safety
///
/// The caller must have enabled EL1 FP/SIMD access and must own the current
/// live FP/SIMD state. Calling this while FP/SIMD is trapped will fault.
pub unsafe fn save_current_state(state: &mut UserFpState) {
    // SAFETY: The caller proves FP/SIMD access and state ownership.
    unsafe { a64_fp_save(state) };
}

/// Restores the current CPU FP/SIMD register file from `state`.
///
/// # Safety
///
/// The caller must have enabled EL1 FP/SIMD access and must ensure the restored
/// state belongs to the execution context that will next use FP/SIMD.
pub unsafe fn restore_current_state(state: &UserFpState) {
    // SAFETY: The caller proves FP/SIMD access and state ownership.
    unsafe { a64_fp_restore(state) };
}

pub fn take_trapped_user_state() -> Option<UserFpState> {
    // SAFETY: Trap entry wrote the flag and state before calling Rust.
    let saved = unsafe { *A64_TRAP_FP_SCRATCH.saved.get() };
    if saved == 0 {
        return None;
    }

    // SAFETY: `saved != 0` means assembly populated the full state image.
    let state = unsafe { *A64_TRAP_FP_SCRATCH.state.get() };
    // SAFETY: Clear the single producer/consumer flag after copying.
    unsafe {
        *A64_TRAP_FP_SCRATCH.saved.get() = 0;
    }
    Some(state)
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
