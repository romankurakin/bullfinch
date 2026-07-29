//! RISC-V per-thread scalar FP state.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(C, align(16))]
pub struct UserFpState {
    fregs: [u64; 32],
    fcsr: u32,
    _reserved: u32,
}

impl UserFpState {
    pub const SIZE: usize = core::mem::size_of::<Self>();
    pub const FREGS_OFFSET: usize = core::mem::offset_of!(Self, fregs);
    pub const FCSR_OFFSET: usize = core::mem::offset_of!(Self, fcsr);

    pub const fn zeroed() -> Self {
        Self {
            fregs: [0; 32],
            fcsr: 0,
            _reserved: 0,
        }
    }

    pub const fn fregs(&self) -> &[u64; 32] {
        &self.fregs
    }

    pub const fn fcsr(&self) -> u32 {
        self.fcsr
    }
}

impl Default for UserFpState {
    fn default() -> Self {
        Self::zeroed()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ThreadFpState {
    state: UserFpState,
    status: StoredFpStatus,
}

impl ThreadFpState {
    pub const fn new() -> Self {
        Self {
            state: UserFpState::zeroed(),
            status: StoredFpStatus::Off,
        }
    }

    pub const fn user_state(&self) -> &UserFpState {
        &self.state
    }

    pub const fn status(&self) -> FpStatus {
        self.status.as_fp_status()
    }

    pub const fn restore_status(&self) -> Option<FpStatus> {
        self.status.restore_status()
    }

    pub fn enable_user_state(&mut self) {
        if matches!(self.status, StoredFpStatus::Off) {
            self.state = UserFpState::zeroed();
            self.status = StoredFpStatus::Initial;
        }
    }

    pub fn save_user_state(&mut self, state: UserFpState) {
        self.state = state;
        self.status = StoredFpStatus::Clean;
        // A saved user state is no longer live-dirty in hardware. Dirty is a
        // CPU-local condition, not a property of this memory image.
        debug_assert_eq!(self.status.as_fp_status(), FpStatus::Clean);
    }

    pub fn save_user_state_with(&mut self, save: impl FnOnce(&mut UserFpState)) {
        save(&mut self.state);
        self.status = StoredFpStatus::Clean;
    }
}

impl Default for ThreadFpState {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum FpStatus {
    Off = 0,
    Initial = 1,
    Clean = 2,
    Dirty = 3,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StoredFpStatus {
    Off,
    Initial,
    Clean,
}

impl StoredFpStatus {
    const fn as_fp_status(self) -> FpStatus {
        match self {
            Self::Off => FpStatus::Off,
            Self::Initial => FpStatus::Initial,
            Self::Clean => FpStatus::Clean,
        }
    }

    const fn restore_status(self) -> Option<FpStatus> {
        match self {
            Self::Off => None,
            Self::Initial => Some(FpStatus::Initial),
            Self::Clean => Some(FpStatus::Clean),
        }
    }
}

const SSTATUS_FS_SHIFT: usize = 13;
const SSTATUS_FS_MASK: usize = 0b11 << SSTATUS_FS_SHIFT;

impl FpStatus {
    pub const fn from_sstatus(sstatus: usize) -> Self {
        match (sstatus & SSTATUS_FS_MASK) >> SSTATUS_FS_SHIFT {
            0 => Self::Off,
            1 => Self::Initial,
            2 => Self::Clean,
            _ => Self::Dirty,
        }
    }

    pub const fn apply_to_sstatus(self, sstatus: usize) -> usize {
        (sstatus & !SSTATUS_FS_MASK) | ((self as usize) << SSTATUS_FS_SHIFT)
    }

    pub const fn needs_save(self) -> bool {
        matches!(self, Self::Dirty)
    }
}

pub const fn instruction_may_access_scalar_fp(instruction: usize) -> bool {
    let instruction = instruction as u32;
    if instruction == 0 {
        return false;
    }

    if instruction & 0b11 != 0b11 {
        return compressed_instruction_may_access_scalar_fp(instruction as u16);
    }

    if matches!(
        instruction & 0x7f,
        0x07 | 0x27 | 0x43 | 0x47 | 0x4b | 0x4f | 0x53
    ) {
        return true;
    }

    is_fp_csr_access(instruction)
}

/// Returns whether an illegal instruction can be the first use of scalar FP.
///
/// Some harts report zero in `stval` instead of instruction bits. Treat that
/// case as a possible first use only while the thread's stored state is Off;
/// after the one retry, a genuinely illegal instruction is reported normally.
pub const fn illegal_instruction_may_be_first_fp_use(
    instruction: usize,
    stored_status: FpStatus,
) -> bool {
    if !matches!(stored_status, FpStatus::Off) {
        return false;
    }
    if instruction == 0 {
        return true;
    }
    instruction_may_access_scalar_fp(instruction)
}

/// The FP control CSRs (fflags, frm, fcsr) are part of the FP state, so with
/// `sstatus.FS = Off` even reading the rounding mode raises an illegal
/// instruction. Thus a thread can hit its first-use trap through a CSR access
/// before it touches any f register. CSR instructions use the SYSTEM opcode
/// with a nonzero funct3; funct3 0 covers ecall, ebreak, and the xret family,
/// and funct3 4 is reserved.
const fn is_fp_csr_access(instruction: u32) -> bool {
    if instruction & 0x7f != 0x73 {
        return false;
    }
    let funct3 = (instruction >> 12) & 0b111;
    if funct3 == 0b000 || funct3 == 0b100 {
        return false;
    }
    // CSR address field, bits 31:20. fflags=0x001, frm=0x002, fcsr=0x003.
    matches!(instruction >> 20, 0x001..=0x003)
}

const fn compressed_instruction_may_access_scalar_fp(instruction: u16) -> bool {
    let quadrant = instruction & 0b11;
    let funct3 = (instruction >> 13) & 0b111;

    matches!(
        (quadrant, funct3),
        (0b00, 0b001) | (0b00, 0b101) | (0b10, 0b001) | (0b10, 0b101)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fp_status_round_trips_through_sstatus() {
        let base = 0xffffusize & !SSTATUS_FS_MASK;

        for status in [
            FpStatus::Off,
            FpStatus::Initial,
            FpStatus::Clean,
            FpStatus::Dirty,
        ] {
            let sstatus = status.apply_to_sstatus(base);

            assert_eq!(FpStatus::from_sstatus(sstatus), status);
            assert_eq!(sstatus & !SSTATUS_FS_MASK, base);
        }
    }

    #[test]
    fn only_dirty_fp_state_needs_save() {
        assert!(!FpStatus::Off.needs_save());
        assert!(!FpStatus::Initial.needs_save());
        assert!(!FpStatus::Clean.needs_save());
        assert!(FpStatus::Dirty.needs_save());
    }

    #[test]
    fn user_fp_state_layout_matches_assembly() {
        assert_eq!(UserFpState::FREGS_OFFSET, 0);
        assert_eq!(UserFpState::FCSR_OFFSET, 256);
        assert_eq!(UserFpState::SIZE, 272);

        let state = UserFpState::zeroed();
        assert_eq!(state.fregs(), &[0; 32]);
        assert_eq!(state.fcsr(), 0);
    }

    #[test]
    fn thread_fp_state_starts_off() {
        let mut state = ThreadFpState::new();

        assert_eq!(state.user_state(), &UserFpState::zeroed());
        assert_eq!(state.status(), FpStatus::Off);
        assert_eq!(state.restore_status(), None);

        state.enable_user_state();
        assert_eq!(state.status(), FpStatus::Initial);
        assert_eq!(state.restore_status(), Some(FpStatus::Initial));

        state.save_user_state(UserFpState::zeroed());
        assert_eq!(state.status(), FpStatus::Clean);
        assert_eq!(state.restore_status(), Some(FpStatus::Clean));

        state.save_user_state_with(|saved| *saved = UserFpState::zeroed());
        assert_eq!(state.status(), FpStatus::Clean);
    }

    #[test]
    fn stored_thread_fp_status_excludes_live_dirty() {
        let mut state = ThreadFpState::new();

        state.enable_user_state();
        state.save_user_state(UserFpState::zeroed());

        assert!(!state.status().needs_save());
    }

    #[test]
    fn detects_scalar_fp_instruction_opcodes() {
        assert!(instruction_may_access_scalar_fp(0x0000_0007));
        assert!(instruction_may_access_scalar_fp(0x0000_0027));
        assert!(instruction_may_access_scalar_fp(0x0000_0053));
        assert!(instruction_may_access_scalar_fp(0x0000_0043));
        assert!(instruction_may_access_scalar_fp(0x0000_2000));
        assert!(instruction_may_access_scalar_fp(0x0000_a000));

        assert!(!instruction_may_access_scalar_fp(0));
        assert!(!instruction_may_access_scalar_fp(0x0000_0013));
        assert!(!instruction_may_access_scalar_fp(0x0000_0003));
    }

    #[test]
    fn retries_missing_illegal_instruction_bits_only_for_first_fp_use() {
        assert!(illegal_instruction_may_be_first_fp_use(0, FpStatus::Off));
        assert!(!illegal_instruction_may_be_first_fp_use(
            0,
            FpStatus::Initial
        ));
        assert!(!illegal_instruction_may_be_first_fp_use(0, FpStatus::Clean));
        assert!(!illegal_instruction_may_be_first_fp_use(
            0x0000_0053,
            FpStatus::Clean
        ));
        assert!(illegal_instruction_may_be_first_fp_use(
            0x0000_0053,
            FpStatus::Off
        ));
    }

    #[test]
    fn detects_fp_csr_accesses() {
        // frcsr a0 (csrrs a0, fcsr, x0).
        assert!(instruction_may_access_scalar_fp(0x0030_2573));
        // fsrm a0, a0 (csrrw a0, frm, a0).
        assert!(instruction_may_access_scalar_fp(0x0025_1573));
        // csrrci x0, fflags, 1.
        assert!(instruction_may_access_scalar_fp(0x0010_f073));

        // ecall: SYSTEM opcode but funct3 0 is not a CSR access.
        assert!(!instruction_may_access_scalar_fp(0x0000_0073));
        // csrrs a0, time, x0: CSR access to a non-FP CSR.
        assert!(!instruction_may_access_scalar_fp(0xc010_2573));
    }
}
