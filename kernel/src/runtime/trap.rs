//! Portable trap handler entry points.
//!
//! Architecture entry code saves registers and calls these handlers. Frame
//! accessors decode raw exception registers into typed causes when needed.
//! The fast interrupt path calls its handler without constructing a full
//! diagnostic frame.

use kernel::trap::{
    dispatch::{InterruptAction, KernelTrapAction, dispatch_kernel_trap},
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
    match crate::hal::interrupt::handle_timer_interrupt(Some(frame.cause())) {
        InterruptAction::Unhandled => panic_trap(TrapReport::from_frame(frame)),
        InterruptAction::Return => {}
        InterruptAction::Reschedule => preempt_from_trap_or_halt(),
    }
}

pub fn handle_fast_interrupt() {
    match crate::hal::interrupt::handle_timer_interrupt(None) {
        InterruptAction::Unhandled => {
            let mut out = crate::console::Console::new();
            out.print("\n[TRAP]\nunhandled interrupt\n");
            crate::hal::cpu::halt();
        }
        InterruptAction::Return => {}
        InterruptAction::Reschedule => preempt_from_trap_or_halt(),
    }
}

fn preempt_from_trap_or_halt() {
    if kernel::task::preempt_from_trap::<ArchTrapContextSwitch>().is_err() {
        crate::console::print_unsafe("\n[PANIC]\ntask: trap preemption failed\n");
        crate::hal::cpu::halt();
    }
}

struct ArchTrapContextSwitch;

impl kernel::task::TrapContextSwitch for ArchTrapContextSwitch {
    unsafe fn switch_fp(old: &mut kernel::fp::ThreadFpState, new: &kernel::fp::ThreadFpState) {
        // SAFETY: `kernel::task` supplies the FP states paired with the outgoing
        // and incoming contexts while trap entry keeps hardware FP disabled.
        unsafe { crate::hal::fp::context_switch(old, new) };
    }

    unsafe fn switch_integer(
        old: &mut crate::hal::context::Context,
        new: &crate::hal::context::Context,
    ) {
        // SAFETY: The task module owns scheduler contexts and only hands us pairs
        // that can be switched at an exception-return boundary. Resumed threads
        // restore IRQ state through `eret` or `sret`; fresh threads enable IRQs
        // in their first-entry trampoline.
        unsafe { crate::hal::context::switch_context_from_trap(old, new) };
    }
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
