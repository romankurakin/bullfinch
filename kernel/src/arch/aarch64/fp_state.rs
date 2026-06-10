//! ARM64 per-thread NEON/FP state.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(C, align(16))]
pub struct UserFpState {
    vregs: [u128; 32],
    fpsr: u32,
    fpcr: u32,
}

impl UserFpState {
    pub const SIZE: usize = core::mem::size_of::<Self>();
    pub const VREGS_OFFSET: usize = core::mem::offset_of!(Self, vregs);
    pub const FPSR_OFFSET: usize = core::mem::offset_of!(Self, fpsr);
    pub const FPCR_OFFSET: usize = core::mem::offset_of!(Self, fpcr);

    pub const fn zeroed() -> Self {
        Self {
            vregs: [0; 32],
            fpsr: 0,
            fpcr: 0,
        }
    }

    pub const fn vregs(&self) -> &[u128; 32] {
        &self.vregs
    }

    pub const fn fpsr(&self) -> u32 {
        self.fpsr
    }

    pub const fn fpcr(&self) -> u32 {
        self.fpcr
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
    valid: bool,
    user_enabled: bool,
}

impl ThreadFpState {
    pub const fn new() -> Self {
        Self {
            state: UserFpState::zeroed(),
            valid: false,
            user_enabled: false,
        }
    }

    pub const fn user_state(&self) -> Option<&UserFpState> {
        if self.valid { Some(&self.state) } else { None }
    }

    pub const fn user_enabled(&self) -> bool {
        self.user_enabled
    }

    pub fn enable_user_state(&mut self) {
        self.valid = true;
        self.user_enabled = true;
    }

    pub fn save_user_state(&mut self, state: UserFpState) {
        self.state = state;
        self.valid = true;
        self.user_enabled = true;
    }
}

impl Default for ThreadFpState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_fp_state_layout_matches_assembly() {
        assert_eq!(UserFpState::VREGS_OFFSET, 0);
        assert_eq!(UserFpState::FPSR_OFFSET, 512);
        assert_eq!(UserFpState::FPCR_OFFSET, 516);
        assert_eq!(UserFpState::SIZE, 528);

        let state = UserFpState::zeroed();
        assert_eq!(state.vregs(), &[0; 32]);
        assert_eq!(state.fpsr(), 0);
        assert_eq!(state.fpcr(), 0);
    }

    #[test]
    fn thread_fp_state_starts_disabled() {
        let mut state = ThreadFpState::new();

        assert_eq!(state.user_state(), None);
        assert!(!state.user_enabled());

        state.enable_user_state();
        assert_eq!(state.user_state(), Some(&UserFpState::zeroed()));
        assert!(state.user_enabled());

        state.save_user_state(UserFpState::zeroed());
        assert_eq!(state.user_state(), Some(&UserFpState::zeroed()));
        assert!(state.user_enabled());
    }
}
