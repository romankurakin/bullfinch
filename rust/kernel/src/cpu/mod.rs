//! CPU primitives selected for the current build target.

#[cfg(all(target_os = "none", target_arch = "aarch64"))]
#[path = "../arch/aarch64/cpu.rs"]
mod selected;
#[cfg(all(target_os = "none", target_arch = "riscv64"))]
#[path = "../arch/riscv64/cpu.rs"]
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
    pub fn disable_interrupts() -> bool {
        false
    }

    pub fn restore_interrupts(_: bool) {}

    pub fn spin_wait() {
        core::hint::spin_loop();
    }
}

#[cfg(not(all(
    target_os = "none",
    any(target_arch = "aarch64", target_arch = "riscv64")
)))]
pub use host::*;
