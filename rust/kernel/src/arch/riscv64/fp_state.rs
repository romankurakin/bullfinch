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
    status: FpStatus,
}

impl ThreadFpState {
    pub const fn new() -> Self {
        Self {
            state: UserFpState::zeroed(),
            status: FpStatus::Off,
        }
    }

    pub const fn user_state(&self) -> &UserFpState {
        &self.state
    }

    pub const fn status(&self) -> FpStatus {
        self.status
    }

    pub fn save_user_state(&mut self, state: UserFpState) {
        self.state = state;
        self.status = FpStatus::Clean;
        // A saved user state is no longer live-dirty in hardware.
        debug_assert_eq!(self.status, FpStatus::Clean);
        debug_assert!(!self.status.needs_save());
    }

    pub fn save_with_status(&mut self, state: UserFpState, status: FpStatus) {
        self.state = state;
        self.status = status;
        // Preserve the caller's architectural FS classification exactly.
        debug_assert_eq!(self.status, status);
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

        state.save_user_state(UserFpState::zeroed());
        assert_eq!(state.status(), FpStatus::Clean);

        state.save_with_status(UserFpState::zeroed(), FpStatus::Dirty);
        assert_eq!(state.status(), FpStatus::Dirty);
    }
}
