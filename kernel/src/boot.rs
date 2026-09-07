//! Boot-time types shared between architecture stubs and the common kernel.
//!
//! These types distinguish physical addresses from hardware thread IDs when
//! architecture code passes control to the common kernel.

use crate::mmu::address::PhysicalAddress;

/// On RISC-V this is the `mhartid` value passed by OpenSBI in `a0`.
/// On ARM64, `None` indicates the primary core.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HartId(usize);

/// Carries the DTB's physical address through both boot phases. The address
/// remains physical after the kernel enters its higher-half virtual mapping.
/// See `startup::init` for the boot sequence.
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
