//! Trap frame layouts.
//!
//! When a trap fires the CPU switches to kernel mode and the assembly entry
//! code saves every register to the stack. These structs describe exactly what
//! that stack image looks like. If you change a field here you must also change
//! the corresponding assembly in `arch/*/trap.rs`.

pub mod arm64 {
    use crate::trap::{
        cause::{self, TrapCause},
        report::TrapFrameSnapshot,
    };

    #[repr(C)]
    pub struct TrapFrame {
        regs: [u64; 31],
        sp_saved: u64,
        elr: u64,
        spsr: u64,
        esr: u64,
        far: u64,
    }

    impl TrapFrameSnapshot for TrapFrame {
        fn architecture_name(&self) -> &'static str {
            "arm64"
        }

        fn program_counter(&self) -> usize {
            self.pc()
        }

        fn cause(&self) -> TrapCause {
            cause::arm64::decode_exception_syndrome(self.cause())
        }

        fn fault_address(&self) -> usize {
            self.fault_addr()
        }

        fn is_from_user(&self) -> bool {
            self.is_from_user()
        }
    }

    impl TrapFrame {
        pub const SIZE: usize = core::mem::size_of::<Self>();
        pub const SAVED_STACK_POINTER_OFFSET: usize = core::mem::offset_of!(TrapFrame, sp_saved);
        pub const LINK_REGISTER_OFFSET: usize = 30 * core::mem::size_of::<u64>();
        pub const EXCEPTION_RETURN_ADDRESS_OFFSET: usize = core::mem::offset_of!(TrapFrame, elr);
        pub const PROGRAM_STATUS_OFFSET: usize = core::mem::offset_of!(TrapFrame, spsr);
        pub const SYNDROME_OFFSET: usize = core::mem::offset_of!(TrapFrame, esr);
        pub const FAULT_ADDRESS_OFFSET: usize = core::mem::offset_of!(TrapFrame, far);

        pub const fn pc(&self) -> usize {
            self.elr as usize
        }

        pub fn set_pc(&mut self, value: usize) {
            self.elr = value as u64;
        }

        pub const fn sp(&self) -> usize {
            self.sp_saved as usize
        }

        pub const fn cause(&self) -> usize {
            self.esr as usize
        }

        pub const fn fault_addr(&self) -> usize {
            self.far as usize
        }

        pub const fn fp(&self) -> usize {
            self.regs[29] as usize
        }

        /// True when the trap came from EL0.
        pub const fn is_from_user(&self) -> bool {
            self.spsr & 0xf == 0
        }

        pub fn reg(&self, index: usize) -> Option<u64> {
            self.regs.get(index).copied()
        }

        pub const fn syscall_num(&self) -> usize {
            self.regs[8] as usize
        }

        pub fn syscall_arg(&self, index: usize) -> Option<usize> {
            self.regs
                .get(index)
                .copied()
                .map(|value| value as usize)
                .filter(|_| index <= 5)
        }

        pub fn set_syscall_return(&mut self, value: usize) {
            self.regs[0] = value as u64;
        }
    }

    #[repr(C)]
    pub struct IrqFrame {
        /// x0-x18 followed by x30. Callee-saved registers stay live across the
        /// Rust IRQ handler and are captured by the context switch continuation
        /// only when the timer preempts.
        regs: [u64; 20],
        elr: u64,
        spsr: u64,
    }

    impl IrqFrame {
        pub const SIZE: usize = core::mem::size_of::<Self>();
        pub const EXCEPTION_RETURN_ADDRESS_OFFSET: usize = core::mem::offset_of!(IrqFrame, elr);
        pub const PROGRAM_STATUS_OFFSET: usize = core::mem::offset_of!(IrqFrame, spsr);
    }

    const _: () = assert!(core::mem::size_of::<TrapFrame>() == 288);
    const _: () = assert!(core::mem::offset_of!(TrapFrame, regs) == 0);
    const _: () = assert!(TrapFrame::SAVED_STACK_POINTER_OFFSET == 248);
    const _: () = assert!(TrapFrame::LINK_REGISTER_OFFSET == 240);
    const _: () = assert!(TrapFrame::EXCEPTION_RETURN_ADDRESS_OFFSET == 256);
    const _: () = assert!(TrapFrame::PROGRAM_STATUS_OFFSET == 264);
    const _: () = assert!(TrapFrame::SYNDROME_OFFSET == 272);
    const _: () = assert!(TrapFrame::FAULT_ADDRESS_OFFSET == 280);
    const _: () = assert!(core::mem::size_of::<IrqFrame>() == 176);
    const _: () = assert!(core::mem::offset_of!(IrqFrame, regs) == 0);
    const _: () = assert!(IrqFrame::EXCEPTION_RETURN_ADDRESS_OFFSET == 160);
    const _: () = assert!(IrqFrame::PROGRAM_STATUS_OFFSET == 168);

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn layout_matches_assembly_contract() {
            assert_eq!(TrapFrame::SIZE, 288);
            assert_eq!(TrapFrame::SAVED_STACK_POINTER_OFFSET, 248);
            assert_eq!(TrapFrame::FAULT_ADDRESS_OFFSET, 280);
            assert_eq!(IrqFrame::SIZE, 176);
            assert_eq!(IrqFrame::EXCEPTION_RETURN_ADDRESS_OFFSET, 160);
        }

        #[test]
        fn reads_registers() {
            let frame = TrapFrame {
                regs: core::array::from_fn(|i| i as u64 + 100),
                sp_saved: 0,
                elr: 0,
                spsr: 0,
                esr: 0,
                far: 0,
            };

            assert_eq!(frame.reg(0), Some(100));
            assert_eq!(frame.reg(1), Some(101));
            assert_eq!(frame.reg(30), Some(130));
            assert_eq!(frame.reg(31), None);
        }

        #[test]
        fn detects_user_origin() {
            let user = TrapFrame {
                regs: [0; 31],
                sp_saved: 0,
                elr: 0,
                spsr: 0x00,
                esr: 0,
                far: 0,
            };
            let kernel = TrapFrame { spsr: 0x05, ..user };

            assert!(user.is_from_user());
            assert!(!kernel.is_from_user());
        }

        #[test]
        fn reads_syscall_abi() {
            let mut frame = TrapFrame {
                regs: [0; 31],
                sp_saved: 0,
                elr: 0,
                spsr: 0,
                esr: 0,
                far: 0,
            };
            frame.regs[8] = 42;
            frame.regs[0] = 100;
            frame.regs[1] = 200;
            frame.regs[5] = 500;

            assert_eq!(frame.syscall_num(), 42);
            assert_eq!(frame.syscall_arg(0), Some(100));
            assert_eq!(frame.syscall_arg(1), Some(200));
            assert_eq!(frame.syscall_arg(5), Some(500));
            assert_eq!(frame.syscall_arg(6), None);

            frame.set_syscall_return(999);
            assert_eq!(frame.regs[0], 999);
        }
    }
}

pub mod riscv64 {
    use crate::trap::{
        cause::{self, TrapCause},
        report::TrapFrameSnapshot,
    };

    #[repr(C)]
    pub struct TrapFrame {
        regs: [u64; 31],
        sp_saved: u64,
        sepc: u64,
        sstatus: u64,
        scause: u64,
        stval: u64,
    }

    impl TrapFrameSnapshot for TrapFrame {
        fn architecture_name(&self) -> &'static str {
            "riscv64"
        }

        fn program_counter(&self) -> usize {
            self.pc()
        }

        fn cause(&self) -> TrapCause {
            cause::riscv64::decode_supervisor_cause(self.cause())
        }

        fn fault_address(&self) -> usize {
            self.fault_addr()
        }

        fn is_from_user(&self) -> bool {
            self.is_from_user()
        }
    }

    impl TrapFrame {
        pub const SIZE: usize = core::mem::size_of::<Self>();
        pub const SAVED_STACK_POINTER_OFFSET: usize = core::mem::offset_of!(TrapFrame, sp_saved);
        pub const PROGRAM_COUNTER_OFFSET: usize = core::mem::offset_of!(TrapFrame, sepc);
        pub const STATUS_OFFSET: usize = core::mem::offset_of!(TrapFrame, sstatus);
        pub const CAUSE_OFFSET: usize = core::mem::offset_of!(TrapFrame, scause);
        pub const TRAP_VALUE_OFFSET: usize = core::mem::offset_of!(TrapFrame, stval);
        pub const LAST_REGISTER_OFFSET: usize = 30 * core::mem::size_of::<u64>();

        pub const fn pc(&self) -> usize {
            self.sepc as usize
        }

        pub fn set_pc(&mut self, value: usize) {
            self.sepc = value as u64;
        }

        pub const fn sp(&self) -> usize {
            self.sp_saved as usize
        }

        pub const fn cause(&self) -> usize {
            self.scause as usize
        }

        pub const fn fault_addr(&self) -> usize {
            self.stval as usize
        }

        pub const fn fp(&self) -> usize {
            self.regs[7] as usize
        }

        /// True when sstatus.SPP says the trap came from U-mode.
        pub const fn is_from_user(&self) -> bool {
            self.sstatus & 0x100 == 0
        }

        /// x0 is synthesized as zero. x2 returns the original saved stack
        /// pointer instead of the adjusted trap stack pointer.
        pub fn reg(&self, index: usize) -> Option<u64> {
            match index {
                0 => Some(0),
                2 => Some(self.sp_saved),
                1..=31 => self.regs.get(index - 1).copied(),
                _ => None,
            }
        }

        pub const fn syscall_num(&self) -> usize {
            self.regs[16] as usize
        }

        pub fn syscall_arg(&self, index: usize) -> Option<usize> {
            if index > 5 {
                return None;
            }
            self.regs
                .get(9 + index)
                .copied()
                .map(|value| value as usize)
        }

        pub fn set_syscall_return(&mut self, value: usize) {
            self.regs[9] = value as u64;
        }
    }

    #[repr(C)]
    pub struct IrqFrame {
        /// ra, t0-t2, a0-a7, and t3-t6. The callee-saved set is preserved by the
        /// Rust call chain and captured by the context switch continuation only
        /// when the timer preempts.
        regs: [u64; 16],
        sepc: u64,
        sstatus: u64,
    }

    impl IrqFrame {
        pub const SIZE: usize = core::mem::size_of::<Self>();
        pub const PROGRAM_COUNTER_OFFSET: usize = core::mem::offset_of!(IrqFrame, sepc);
        pub const STATUS_OFFSET: usize = core::mem::offset_of!(IrqFrame, sstatus);
    }

    const _: () = assert!(core::mem::size_of::<TrapFrame>() == 288);
    const _: () = assert!(core::mem::offset_of!(TrapFrame, regs) == 0);
    const _: () = assert!(TrapFrame::SAVED_STACK_POINTER_OFFSET == 248);
    const _: () = assert!(TrapFrame::PROGRAM_COUNTER_OFFSET == 256);
    const _: () = assert!(TrapFrame::STATUS_OFFSET == 264);
    const _: () = assert!(TrapFrame::CAUSE_OFFSET == 272);
    const _: () = assert!(TrapFrame::TRAP_VALUE_OFFSET == 280);
    const _: () = assert!(TrapFrame::LAST_REGISTER_OFFSET == 240);
    const _: () = assert!(core::mem::size_of::<IrqFrame>() == 144);
    const _: () = assert!(core::mem::offset_of!(IrqFrame, regs) == 0);
    const _: () = assert!(IrqFrame::PROGRAM_COUNTER_OFFSET == 128);
    const _: () = assert!(IrqFrame::STATUS_OFFSET == 136);

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn layout_matches_assembly_contract() {
            assert_eq!(TrapFrame::SIZE, 288);
            assert_eq!(TrapFrame::SAVED_STACK_POINTER_OFFSET, 248);
            assert_eq!(TrapFrame::TRAP_VALUE_OFFSET, 280);
            assert_eq!(TrapFrame::LAST_REGISTER_OFFSET, 240);
            assert_eq!(IrqFrame::SIZE, 144);
            assert_eq!(IrqFrame::PROGRAM_COUNTER_OFFSET, 128);
        }

        #[test]
        fn reads_registers_with_riscv_special_cases() {
            let frame = TrapFrame {
                regs: core::array::from_fn(|i| i as u64 + 100),
                sp_saved: 0xdead_beef,
                sepc: 0,
                sstatus: 0,
                scause: 0,
                stval: 0,
            };

            assert_eq!(frame.reg(0), Some(0));
            assert_eq!(frame.reg(1), Some(100));
            assert_eq!(frame.reg(2), Some(0xdead_beef));
            assert_eq!(frame.reg(3), Some(102));
            assert_eq!(frame.reg(32), None);
        }

        #[test]
        fn detects_user_origin() {
            let user = TrapFrame {
                regs: [0; 31],
                sp_saved: 0,
                sepc: 0,
                sstatus: 0x00,
                scause: 0,
                stval: 0,
            };
            let kernel = TrapFrame {
                sstatus: 0x100,
                ..user
            };

            assert!(user.is_from_user());
            assert!(!kernel.is_from_user());
        }

        #[test]
        fn reads_syscall_abi() {
            let mut frame = TrapFrame {
                regs: [0; 31],
                sp_saved: 0,
                sepc: 0,
                sstatus: 0,
                scause: 0,
                stval: 0,
            };
            frame.regs[16] = 42;
            frame.regs[9] = 100;
            frame.regs[10] = 200;
            frame.regs[14] = 500;

            assert_eq!(frame.syscall_num(), 42);
            assert_eq!(frame.syscall_arg(0), Some(100));
            assert_eq!(frame.syscall_arg(1), Some(200));
            assert_eq!(frame.syscall_arg(5), Some(500));
            assert_eq!(frame.syscall_arg(6), None);

            frame.set_syscall_return(999);
            assert_eq!(frame.regs[9], 999);
        }
    }
}
