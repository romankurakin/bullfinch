//! Kernel context model.
//!
//! Bare-metal builds use the selected architecture context module. Host tests
//! use a layout-independent placeholder so scheduler ownership can be tested
//! without assembly.

#[cfg(all(target_os = "none", target_arch = "aarch64"))]
#[path = "../arch/aarch64/context.rs"]
mod selected;
#[cfg(all(target_os = "none", target_arch = "riscv64"))]
#[path = "../arch/riscv64/context.rs"]
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
    #[repr(C, align(16))]
    #[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
    pub struct Context {
        entry: usize,
        stack_pointer: usize,
        entry_data: usize,
    }

    impl Context {
        pub const SIZE: usize = 128;

        pub const fn new(entry_pc: usize, stack_top: usize) -> Self {
            Self {
                entry: entry_pc,
                stack_pointer: stack_top,
                entry_data: 0,
            }
        }

        pub const fn empty() -> Self {
            Self {
                entry: 0,
                stack_pointer: 0,
                entry_data: 0,
            }
        }

        pub fn set_entry_data(&mut self, entry: usize, arg: usize) {
            self.entry = entry;
            self.entry_data = arg;
        }

        pub const fn stack_pointer(self) -> usize {
            self.stack_pointer
        }
    }

    pub fn thread_trampoline_address() -> usize {
        0
    }

    /// Host-test placeholder for the architecture switch ABI.
    ///
    /// # Safety
    ///
    /// Bare-metal callers must use the architecture implementation. Host tests
    /// must not rely on this function to transfer execution.
    pub unsafe fn switch_context(_old: &mut Context, _new: &Context) {}
}

#[cfg(not(all(
    target_os = "none",
    any(target_arch = "aarch64", target_arch = "riscv64")
)))]
pub use host::*;
