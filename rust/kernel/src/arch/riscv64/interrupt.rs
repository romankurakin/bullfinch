//! RISC-V interrupt setup.
//!
//! OpenSBI owns the machine-mode timer and platform interrupt controller before
//! entering supervisor mode. Local code enables timer delivery after programming
//! SBI deadlines.

use kernel::{
    hwinfo::HardwareInfo,
    trap::cause::{InterruptKind, TrapCause},
};

pub fn init(_: &HardwareInfo) {}

pub fn enable_timer_interrupt() {
    super::timer::enable_local_timer_interrupts();
}

#[allow(dead_code)]
pub fn end_of_interrupt(_: u32) {}

pub fn handle_timer_interrupt(cause: Option<TrapCause>) -> bool {
    if cause.and_then(TrapCause::interrupt_kind) == Some(InterruptKind::SupervisorTimer) {
        crate::runtime::clock::handle_timer_irq();
        true
    } else {
        false
    }
}
