//! Portable trap handler entry points.
//!
//! Architecture-specific assembly saves the register frame, decodes the cause,
//! and then calls one of these functions. By the time we get here the trap has
//! already been typed, so we never touch raw CSRs.

use kernel::trap::{
    dispatch::{KernelTrapAction, dispatch_kernel_trap},
    report::{TrapFrameSnapshot, TrapReport},
};

pub fn handle_kernel_trap(frame: &mut impl TrapFrameSnapshot) {
    match dispatch_kernel_trap(frame) {
        KernelTrapAction::Return => {}
        KernelTrapAction::Panic(report) => panic_trap(report),
    }
}

#[cfg(target_arch = "riscv64")]
pub fn handle_kernel_interrupt(frame: &mut impl TrapFrameSnapshot) {
    if crate::hal::interrupt::handle_timer_interrupt(Some(frame.cause())) {
        let _ = kernel::task::preempt_from_trap(switch_context);
        return;
    }

    panic_trap(TrapReport::from_frame(frame));
}

#[cfg(target_arch = "aarch64")]
pub fn handle_arch_interrupt() {
    if !crate::hal::interrupt::handle_timer_interrupt(None) {
        let mut out = crate::console::Console::new();
        out.print("\n[TRAP]\nunhandled interrupt\n");
        crate::hal::cpu::halt();
    }
    let _ = kernel::task::preempt_from_trap(switch_context);
}

unsafe fn switch_context(
    old: &mut crate::hal::context::Context,
    new: &crate::hal::context::Context,
) {
    // SAFETY: The task module owns scheduler contexts and only hands us pairs
    // that can be switched at a trap-return boundary.
    unsafe { crate::hal::context::switch_context(old, new) };
}

fn panic_trap(report: TrapReport) -> ! {
    let mut out = crate::console::Console::new();

    out.print("\n[TRAP:");
    out.print(report.architecture_name);
    out.print("]\n");
    out.print("pc = ");
    out.print_hex_usize(report.program_counter);
    out.print("\n");
    out.print("cause = ");
    out.print(report.cause.name());
    out.print(" (");
    out.print_hex_usize(report.cause.raw());
    out.print(")");
    out.print("\n");
    out.print("fault = ");
    out.print_hex_usize(report.fault_address);
    out.print("\n");
    out.print("origin = ");
    out.print(if report.from_user { "user" } else { "kernel" });
    out.print("\n");

    crate::hal::cpu::halt()
}
