//! Portable trap reports.
//!
//! Architecture code owns the exact trap-frame layout. Portable code sees only
//! the fields it needs for diagnostics and dispatch, extracted once into a
//! small snapshot.

use super::cause::TrapCause;

pub trait TrapFrameSnapshot {
    fn architecture_name(&self) -> &'static str;
    fn program_counter(&self) -> usize;
    fn cause(&self) -> TrapCause;
    fn fault_address(&self) -> usize;
    fn is_from_user(&self) -> bool;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrapReport {
    pub architecture_name: &'static str,
    pub program_counter: usize,
    pub cause: TrapCause,
    pub fault_address: usize,
    pub from_user: bool,
}

impl TrapReport {
    pub fn from_frame(frame: &impl TrapFrameSnapshot) -> Self {
        let cause = frame.cause();
        Self {
            architecture_name: frame.architecture_name(),
            program_counter: frame.program_counter(),
            cause,
            fault_address: frame.fault_address(),
            from_user: frame.is_from_user(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trap::cause;

    struct FakeFrame;

    impl TrapFrameSnapshot for FakeFrame {
        fn architecture_name(&self) -> &'static str {
            "test"
        }

        fn program_counter(&self) -> usize {
            0x1000
        }

        fn cause(&self) -> TrapCause {
            TrapCause::new(cause::TrapKind::PageFault, 13, "load page fault")
        }

        fn fault_address(&self) -> usize {
            0x2000
        }

        fn is_from_user(&self) -> bool {
            true
        }
    }

    #[test]
    fn snapshots_common_trap_fields() {
        assert_eq!(
            TrapReport::from_frame(&FakeFrame),
            TrapReport {
                architecture_name: "test",
                program_counter: 0x1000,
                cause: TrapCause::new(cause::TrapKind::PageFault, 13, "load page fault"),
                fault_address: 0x2000,
                from_user: true,
            }
        );
    }
}
