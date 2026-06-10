//! Architecture-neutral trap causes.
//!
//! Raw trap registers are architecture-specific. ARM64 has exception classes
//! in ESR_EL1; RISC-V has cause codes in scause. Portable code should not have
//! to know about either. Each architecture module decodes its own register once
//! and hands the rest of the kernel a typed `TrapCause`.
//!
//! See ARM Architecture Reference Manual, D1.4 (Exceptions).
//! See RISC-V Privileged Specification, Chapter 12 (Supervisor-Level ISA).

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrapCause {
    kind: TrapKind,
    raw: usize,
    name: &'static str,
}

impl TrapCause {
    pub const fn new(kind: TrapKind, raw: usize, name: &'static str) -> Self {
        Self { kind, raw, name }
    }

    pub const fn raw(self) -> usize {
        self.raw
    }

    pub const fn kind(self) -> TrapKind {
        self.kind
    }

    pub const fn name(self) -> &'static str {
        self.name
    }

    pub const fn is_syscall(self) -> bool {
        matches!(self.kind, TrapKind::Syscall)
    }

    pub const fn is_page_fault(self) -> bool {
        matches!(self.kind, TrapKind::PageFault)
    }

    pub const fn is_interrupt(self) -> bool {
        matches!(self.kind, TrapKind::Interrupt(_))
    }

    pub const fn interrupt_kind(self) -> Option<InterruptKind> {
        match self.kind {
            TrapKind::Interrupt(kind) => Some(kind),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrapKind {
    Unknown,
    Syscall,
    PageFault,
    Interrupt(InterruptKind),
    Breakpoint,
    IllegalInstruction,
    AlignmentFault,
    FloatingPointUnavailable,
    SystemError,
    Other,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InterruptKind {
    Unknown,
    SupervisorSoftware,
    SupervisorTimer,
    SupervisorExternal,
}

pub mod arm64 {
    use super::{TrapCause, TrapKind};

    const EXCEPTION_CLASS_SHIFT: usize = 26;
    const EXCEPTION_CLASS_MASK: usize = 0x3f;

    pub const fn decode_exception_syndrome(esr: usize) -> TrapCause {
        let class = ((esr >> EXCEPTION_CLASS_SHIFT) & EXCEPTION_CLASS_MASK) as u8;
        let (kind, name) = match class {
            0x00 => (TrapKind::Unknown, "unknown exception"),
            0x01 => (TrapKind::Other, "wfi/wfe trapped"),
            0x07 => (TrapKind::FloatingPointUnavailable, "simd/fp access"),
            0x11 => (TrapKind::Syscall, "svc (syscall, aarch32)"),
            0x12 => (TrapKind::Other, "hvc (hypervisor call, aarch32)"),
            0x13 => (TrapKind::Other, "smc (secure monitor call, aarch32)"),
            0x15 => (TrapKind::Syscall, "svc (syscall)"),
            0x16 => (TrapKind::Other, "hvc (hypervisor call)"),
            0x17 => (TrapKind::Other, "smc (secure monitor call)"),
            0x18 => (TrapKind::Other, "msr/mrs/sys trapped"),
            0x20 => (TrapKind::PageFault, "instruction abort (lower level)"),
            0x21 => (TrapKind::PageFault, "instruction abort (same level)"),
            0x22 => (TrapKind::AlignmentFault, "program counter alignment fault"),
            0x24 => (TrapKind::PageFault, "data abort (lower level)"),
            0x25 => (TrapKind::PageFault, "data abort (same level)"),
            0x26 => (TrapKind::AlignmentFault, "stack pointer alignment fault"),
            0x2f => (TrapKind::SystemError, "system error"),
            0x30 => (TrapKind::Breakpoint, "breakpoint (lower level)"),
            0x31 => (TrapKind::Breakpoint, "breakpoint (same level)"),
            0x3c => (TrapKind::Breakpoint, "brk instruction"),
            _ => (TrapKind::Other, "other exception"),
        };

        TrapCause::new(kind, esr, name)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn decodes_syscall_from_esr_exception_class() {
            let cause = decode_exception_syndrome(0x15usize << EXCEPTION_CLASS_SHIFT);

            assert_eq!(cause.kind(), TrapKind::Syscall);
            assert!(cause.is_syscall());
            assert_eq!(cause.name(), "svc (syscall)");
        }

        #[test]
        fn decodes_data_abort_as_page_fault_input() {
            let raw = 0x25usize << EXCEPTION_CLASS_SHIFT;
            let cause = decode_exception_syndrome(raw);

            assert_eq!(cause.raw(), raw);
            assert_eq!(cause.kind(), TrapKind::PageFault);
            assert!(cause.is_page_fault());
            assert_eq!(cause.name(), "data abort (same level)");
        }
    }
}

pub mod riscv64 {
    use super::{InterruptKind, TrapCause, TrapKind};

    const INTERRUPT_BIT: usize = 1usize << (usize::BITS as usize - 1);
    const CAUSE_CODE_MASK: usize = !INTERRUPT_BIT;

    pub const fn decode_supervisor_cause(scause: usize) -> TrapCause {
        if scause & INTERRUPT_BIT != 0 {
            decode_interrupt(scause, scause & CAUSE_CODE_MASK)
        } else {
            decode_exception(scause)
        }
    }

    const fn decode_interrupt(raw: usize, code: usize) -> TrapCause {
        let (kind, name) = match code {
            1 => (
                InterruptKind::SupervisorSoftware,
                "supervisor software interrupt",
            ),
            5 => (InterruptKind::SupervisorTimer, "supervisor timer interrupt"),
            9 => (
                InterruptKind::SupervisorExternal,
                "supervisor external interrupt",
            ),
            _ => (InterruptKind::Unknown, "unknown interrupt"),
        };

        TrapCause::new(TrapKind::Interrupt(kind), raw, name)
    }

    const fn decode_exception(scause: usize) -> TrapCause {
        let (kind, name) = match scause {
            0 => (TrapKind::AlignmentFault, "instruction address misaligned"),
            1 => (TrapKind::Other, "instruction access fault"),
            2 => (TrapKind::IllegalInstruction, "illegal instruction"),
            3 => (TrapKind::Breakpoint, "breakpoint"),
            4 => (TrapKind::AlignmentFault, "load address misaligned"),
            5 => (TrapKind::Other, "load access fault"),
            6 => (TrapKind::AlignmentFault, "store address misaligned"),
            7 => (TrapKind::Other, "store access fault"),
            8 => (TrapKind::Syscall, "environment call from user mode"),
            9 => (TrapKind::Syscall, "environment call from supervisor mode"),
            11 => (TrapKind::Syscall, "environment call from machine mode"),
            12 => (TrapKind::PageFault, "instruction page fault"),
            13 => (TrapKind::PageFault, "load page fault"),
            15 => (TrapKind::PageFault, "store page fault"),
            20 => (TrapKind::PageFault, "instruction guest page fault"),
            21 => (TrapKind::PageFault, "load guest page fault"),
            22 => (TrapKind::Other, "virtual instruction"),
            23 => (TrapKind::PageFault, "store guest page fault"),
            _ => (TrapKind::Unknown, "unknown trap"),
        };

        TrapCause::new(kind, scause, name)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn decodes_exception_and_interrupt_from_scause() {
            let page_fault = decode_supervisor_cause(13);
            let timer = decode_supervisor_cause(INTERRUPT_BIT | 5);

            assert_eq!(page_fault.kind(), TrapKind::PageFault);
            assert!(page_fault.is_page_fault());
            assert_eq!(page_fault.name(), "load page fault");
            assert_eq!(
                timer.kind(),
                TrapKind::Interrupt(InterruptKind::SupervisorTimer)
            );
            assert!(timer.is_interrupt());
            assert_eq!(timer.interrupt_kind(), Some(InterruptKind::SupervisorTimer));
            assert_eq!(timer.name(), "supervisor timer interrupt");
        }

        #[test]
        fn preserves_unknown_riscv_raw_values() {
            let cause = decode_supervisor_cause(0x1234);

            assert_eq!(cause.raw(), 0x1234);
            assert_eq!(cause.kind(), TrapKind::Unknown);
            assert_eq!(cause.name(), "unknown trap");
        }
    }
}
