//! RISC-V scalar FP controls.
//!
//! Trap entry records `sstatus.FS` and disables FP but leaves the user's values
//! in the registers. A thread switch saves outgoing state only when FS is
//! Dirty, which marks state that may differ from the saved image. It then
//! restores the incoming thread's state. Returning to the same thread restores
//! the recorded FS value without copying the register contents.
//!
//! The kernel target excludes F and D, the scalar floating-point extensions.
//! Compiled Rust therefore cannot accidentally use scalar FP.

use core::{
    arch::{asm, global_asm},
    cell::UnsafeCell,
};

use kernel::fp::{FpStatus, ThreadFpState, UserFpState};

#[repr(C, align(16))]
pub struct TrapFpScratch {
    return_status: UnsafeCell<u8>,
}

// SAFETY: RISC-V boot admits one hart into Rust and parks the rest, so current
// trap handling is single-hart. Trap entry records the interrupted user FS
// state and trap exit consumes it on the same hart. TODO(smp): replace this
// with per-hart scratch storage before secondary harts can enter U-mode.
unsafe impl Sync for TrapFpScratch {}

impl TrapFpScratch {
    pub const RETURN_STATUS_OFFSET: usize = core::mem::offset_of!(Self, return_status);

    const fn new() -> Self {
        Self {
            return_status: UnsafeCell::new(FpStatus::Off as u8),
        }
    }
}

pub(super) static RV64_TRAP_FP_SCRATCH: TrapFpScratch = TrapFpScratch::new();

global_asm!(
    r#"
    # The kernel target is rv64imac, so the assembler rejects FP instructions
    # by default. Enable F and D for this assembly block alone. Compiled Rust
    # still uses the kernel's soft-float target.
    .option push
    .option arch, +f, +d
    .text
    .macro rv64_store_fp_state base
    .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    fsd f\n, (8 * \n)(\base)
    .endr
    .irp n, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    fsd f\n, (8 * \n)(\base)
    .endr
    csrr t0, fcsr
    sw t0, {fcsr_offset}(\base)
    .endm

    .macro rv64_load_fp_state base
    .irp n, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    fld f\n, (8 * \n)(\base)
    .endr
    .irp n, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
    fld f\n, (8 * \n)(\base)
    .endr
    lwu t0, {fcsr_offset}(\base)
    csrw fcsr, t0
    .endm

    .global rv64_fp_save
    .type rv64_fp_save, @function
rv64_fp_save:
    rv64_store_fp_state a0
    ret

    .global rv64_fp_restore
    .type rv64_fp_restore, @function
rv64_fp_restore:
    rv64_load_fp_state a0
    ret

    .purgem rv64_store_fp_state
    .purgem rv64_load_fp_state
    .option pop
    "#,
    fcsr_offset = const UserFpState::FCSR_OFFSET,
);

unsafe extern "C" {
    pub(super) fn rv64_fp_save(state: *mut UserFpState);
    pub(super) fn rv64_fp_restore(state: *const UserFpState);
}

pub fn set_status(status: FpStatus) {
    let next = status.apply_to_sstatus(read_sstatus());
    // SAFETY: `next` preserves the non-FS bits read from local hart state and
    // changes only sstatus.FS.
    unsafe {
        asm!(
            "csrw sstatus, {next}",
            next = in(reg) next,
            options(nomem, nostack, preserves_flags)
        );
    }
}

pub fn disable_scalar_fp() {
    set_status(FpStatus::Off);
}

pub fn activate_user_state(thread: &ThreadFpState) {
    let status = thread
        .restore_status()
        .expect("activated RISC-V FP state must be restorable");
    restore_for_user(thread.user_state(), status);
}

/// Transfers the resident scalar FP register file at a scheduler context switch.
///
/// # Safety
///
/// Trap entry must have recorded the outgoing user FS state and set hardware
/// FS to Off. `old` and `new` must be the scheduler's actual switch pair.
pub unsafe fn context_switch(old: &mut ThreadFpState, new: &ThreadFpState) {
    let old_status = return_status();
    debug_assert_eq!(
        matches!(old_status, FpStatus::Off),
        matches!(old.status(), FpStatus::Off)
    );
    if old_status.needs_save() {
        set_status(FpStatus::Dirty);
        old.save_user_state_with(|state| {
            // SAFETY: The outgoing thread owns the dirty resident register file
            // and hardware FS was enabled immediately above.
            unsafe { save_current_state(state) };
        });
        disable_scalar_fp();
    }

    match new.restore_status() {
        None => set_return_status(FpStatus::Off),
        Some(status @ (FpStatus::Initial | FpStatus::Clean)) => {
            restore_for_user(new.user_state(), status);
        }
        Some(FpStatus::Off | FpStatus::Dirty) => {
            unreachable!("thread FP restore status excludes off/dirty")
        }
    }
}

/// Saves the current scalar FP register file into `state`.
///
/// # Safety
///
/// The caller must enable scalar FP on the current hart before this call and
/// own the live FP state. If `sstatus.FS=Off`, this function traps.
pub unsafe fn save_current_state(state: &mut UserFpState) {
    // SAFETY: The caller proves FP access and state ownership.
    unsafe { rv64_fp_save(state) };
}

/// Restores the current scalar FP register file from `state`.
///
/// # Safety
///
/// The caller must enable scalar FP on the current hart before this call.
/// The restored state must belong to the execution context that will next use FP.
pub unsafe fn restore_current_state(state: &UserFpState) {
    // SAFETY: The caller proves FP access and state ownership.
    unsafe { rv64_fp_restore(state) };
}

fn restore_for_user(state: &UserFpState, status: FpStatus) {
    debug_assert!(matches!(status, FpStatus::Initial | FpStatus::Clean));
    set_status(FpStatus::Dirty);
    // SAFETY: The current trap handler owns the hart FP register file and will
    // disable kernel access before returning to the selected user thread.
    unsafe { restore_current_state(state) };
    disable_scalar_fp();
    set_return_status(status);
}

fn return_status() -> FpStatus {
    // SAFETY: Trap entry is the single producer and the current trap handler is
    // the single consumer while secondary harts remain parked.
    let status = unsafe { *RV64_TRAP_FP_SCRATCH.return_status.get() };
    match status {
        0 => FpStatus::Off,
        1 => FpStatus::Initial,
        2 => FpStatus::Clean,
        _ => FpStatus::Dirty,
    }
}

fn set_return_status(status: FpStatus) {
    // SAFETY: The current trap handler exclusively prepares this hart's return
    // state while secondary harts remain parked.
    unsafe {
        *RV64_TRAP_FP_SCRATCH.return_status.get() = status as u8;
    }
}

fn read_sstatus() -> usize {
    let value: usize;
    // SAFETY: Reading sstatus is local hart state.
    unsafe {
        asm!("csrr {value}, sstatus", value = out(reg) value, options(nomem, nostack, preserves_flags))
    };
    value
}
