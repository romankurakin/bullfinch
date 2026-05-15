//! Boot-time types shared between architecture stubs and the common kernel.
//!
//! Thin newtypes over raw integers. They prevent passing a physical address
//! where a hart ID is expected at the boot handoff boundary.

use crate::mmu::address::PhysicalAddress;

/// On RISC-V this is the `mhartid` value passed by OpenSBI in `a0`.
/// On ARM64 there is no direct equivalent; `None` indicates the primary core.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HartId(usize);

/// Used before the MMU is enabled and again after the higher-half mapping
/// is live. See `startup::init` for the two-phase init sequence.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceTreeBlobPhysicalAddress(PhysicalAddress);

impl HartId {
    pub const fn new(raw: usize) -> Self {
        Self(raw)
    }

    pub const fn get(self) -> usize {
        self.0
    }
}

impl DeviceTreeBlobPhysicalAddress {
    pub const fn new(raw: usize) -> Self {
        Self(PhysicalAddress::new(raw))
    }

    pub const fn get(self) -> usize {
        self.0.get()
    }
}
