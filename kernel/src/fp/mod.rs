//! FP/SIMD thread state selected for the current build target.

#[cfg(all(target_os = "none", target_arch = "aarch64"))]
#[path = "../arch/aarch64/fp_state.rs"]
mod selected;
#[cfg(all(target_os = "none", target_arch = "riscv64"))]
#[path = "../arch/riscv64/fp_state.rs"]
mod selected;

#[cfg(all(
    target_os = "none",
    any(target_arch = "aarch64", target_arch = "riscv64")
))]
pub use selected::*;

#[cfg(not(all(
    target_os = "none",
    any(target_arch = "aarch64", target_arch = "riscv64")
)))]
mod host {
    #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
    pub struct ThreadFpState {
        enabled: bool,
    }

    #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
    pub struct UserFpState;

    impl ThreadFpState {
        pub const fn new() -> Self {
            Self { enabled: false }
        }

        pub fn enable_user_state(&mut self) {
            self.enabled = true;
        }

        pub fn save_user_state(&mut self, _: UserFpState) {
            self.enabled = true;
        }

        pub fn save_user_state_with(&mut self, save: impl FnOnce(&mut UserFpState)) {
            let mut state = UserFpState;
            save(&mut state);
            self.enabled = true;
        }
    }

    impl UserFpState {
        pub const fn zeroed() -> Self {
            Self
        }
    }
}

#[cfg(not(all(
    target_os = "none",
    any(target_arch = "aarch64", target_arch = "riscv64")
)))]
pub use host::*;

#[cfg(test)]
#[path = "../arch/aarch64/fp_state.rs"]
mod aarch64_state;
#[cfg(test)]
#[path = "../arch/riscv64/fp_state.rs"]
mod riscv64_state;
