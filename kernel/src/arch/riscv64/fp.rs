//! RISC-V scalar FP controls.

#![allow(
    dead_code,
    reason = "Rung 9 wires scalar FP controls before user-mode FP consumes them"
)]

use core::{
    arch::{asm, global_asm},
    cell::UnsafeCell,
};

use kernel::fp::{FpStatus, ThreadFpState, UserFpState};

#[repr(C, align(16))]
pub struct TrapFpScratch {
    state: UnsafeCell<UserFpState>,
    saved: UnsafeCell<u8>,
}

// SAFETY: RISC-V boot admits one hart into Rust and parks the rest, so current
// trap handling is single-hart. TODO(smp): replace this with per-hart scratch
// storage before secondary harts can enter U-mode.
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

pub(super) static RV64_TRAP_FP_SCRATCH: TrapFpScratch = TrapFpScratch::new();

global_asm!(
    r#"
    # The kernel target is rv64imac, so the assembler rejects FP instructions
    # by default. Enable F and D for this block alone; the compiler still
    # cannot emit FP anywhere in kernel code.
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

pub fn current_status() -> FpStatus {
    FpStatus::from_sstatus(read_sstatus())
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

pub fn prepare_user_restore(thread: &ThreadFpState) {
    match thread.restore_status() {
        None => clear_pending_user_restore(),
        Some(FpStatus::Initial) => {
            let zero = UserFpState::zeroed();
            prepare_restore_state(&zero, FpStatus::Initial);
        }
        Some(FpStatus::Clean) => prepare_restore_state(thread.user_state(), FpStatus::Clean),
        Some(FpStatus::Off | FpStatus::Dirty) => {
            unreachable!("thread FP restore status excludes off/dirty")
        }
    }
}

fn prepare_restore_state(state: &UserFpState, status: FpStatus) {
    // SAFETY: Trap exit is the only consumer of this single-hart scratch slot.
    // It runs after this Rust handler returns and clears the status before `sret`.
    unsafe {
        *RV64_TRAP_FP_SCRATCH.state.get() = *state;
        *RV64_TRAP_FP_SCRATCH.saved.get() = status as u8;
    }
}

pub fn clear_pending_user_restore() {
    // SAFETY: This status byte is local to the parked-single-hart trap path.
    unsafe {
        *RV64_TRAP_FP_SCRATCH.saved.get() = 0;
    }
}

/// Saves the current scalar FP register file into `state`.
///
/// # Safety
///
/// The caller must have enabled scalar FP for the current hart and must own the
/// live FP state. Calling this with `sstatus.FS=Off` will trap.
pub unsafe fn save_current_state(state: &mut UserFpState) {
    // SAFETY: The caller proves FP access and state ownership.
    unsafe { rv64_fp_save(state) };
}

/// Restores the current scalar FP register file from `state`.
///
/// # Safety
///
/// The caller must have enabled scalar FP for the current hart and must ensure
/// the restored state belongs to the execution context that will next use FP.
pub unsafe fn restore_current_state(state: &UserFpState) {
    // SAFETY: The caller proves FP access and state ownership.
    unsafe { rv64_fp_restore(state) };
}

pub fn take_trapped_user_state() -> Option<UserFpState> {
    // SAFETY: Trap entry wrote the flag and state before calling Rust.
    let saved = unsafe { *RV64_TRAP_FP_SCRATCH.saved.get() };
    if saved == 0 {
        return None;
    }

    // SAFETY: `saved != 0` means assembly populated the full state image.
    let state = unsafe { *RV64_TRAP_FP_SCRATCH.state.get() };
    // SAFETY: Clear the single producer/consumer flag after copying.
    unsafe {
        *RV64_TRAP_FP_SCRATCH.saved.get() = 0;
    }
    Some(state)
}

fn read_sstatus() -> usize {
    let value: usize;
    // SAFETY: Reading sstatus is local hart state.
    unsafe {
        asm!("csrr {value}, sstatus", value = out(reg) value, options(nomem, nostack, preserves_flags))
    };
    value
}
