//! RISC-V Interrupt Controller Initialization.
//!
//! SBI (OpenSBI) configures PLIC/CLINT at M-mode before jumping to S-mode.
//!
//! See RISC-V Platform-Level Interrupt Controller Specification.

/// Initialize interrupt controller. No-op on RISC-V (SBI handles setup).
pub fn init() void {}
