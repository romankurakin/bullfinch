//! Portable trap dispatch policy.
//!
//! The dispatcher builds a panic report for each kernel trap passed to it.
//! Architecture handlers handle user FP activation before calling this policy.
//! Syscall, page-fault recovery, and breakpoint policies remain future work.

use super::report::{TrapFrameSnapshot, TrapReport};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum KernelTrapAction {
    Return,
    Panic(TrapReport),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InterruptAction {
    Unhandled,
    Return,
    Reschedule,
}

pub fn dispatch_kernel_trap(frame: &mut impl TrapFrameSnapshot) -> KernelTrapAction {
    KernelTrapAction::Panic(TrapReport::from_frame(frame))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trap::cause::{TrapCause, TrapKind};

    struct FakeFrame;

    impl TrapFrameSnapshot for FakeFrame {
        fn architecture_name(&self) -> &'static str {
            "test"
        }

        fn program_counter(&self) -> usize {
            0x4000
        }

        fn cause(&self) -> TrapCause {
            TrapCause::new(TrapKind::PageFault, 0x25 << 26, "data abort")
        }

        fn fault_address(&self) -> usize {
            0x8000
        }

        fn is_from_user(&self) -> bool {
            false
        }
    }

    #[test]
    fn unexpected_kernel_traps_panic_with_report() {
        let mut frame = FakeFrame;

        assert_eq!(
            dispatch_kernel_trap(&mut frame),
            KernelTrapAction::Panic(TrapReport {
                architecture_name: "test",
                program_counter: 0x4000,
                cause: TrapCause::new(TrapKind::PageFault, 0x25 << 26, "data abort"),
                fault_address: 0x8000,
                from_user: false,
            })
        );
    }
}
