//! Two-phase kernel boot.
//!
//! Boot starts with the MMU off. The DTB can live outside the small identity
//! map left by firmware, so boot is split in two phases. The physical phase
//! builds enough page tables to enter the higher half. The virtual phase parses
//! the DTB, discovers hardware, and expands the physmap to cover RAM.

use kernel::{
    boot::DeviceTreeBlobPhysicalAddress,
    fdt::{Fdt, FdtError},
    hwinfo::HardwareInfo,
    limits::DEVICE_TREE_BLOB_MAX_SIZE,
    mmu::PhysicalAddress,
};

use crate::{hal, startup::log as boot_log};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootError {
    MissingDeviceTree,
    DeviceTreeHeader,
    DeviceTreeTooLarge,
    DeviceTreeMagic,
    DeviceTreeMisaligned,
}

/// Magic value at byte offset 0 of every flat device-tree blob.
/// See "Devicetree Specification", section 5.2 (Header).
const FDT_MAGIC: u32 = 0xd00d_feed;

/// Phase one: physical boot.
///
/// Runs with the MMU off. Traps and page tables are set up now, but the DTB
/// is not parsed yet because it may sit above the tiny identity map.
pub fn phys_init(dtb: DeviceTreeBlobPhysicalAddress) {
    boot_log::header();
    boot_log::uart();
    hal::trap::init();
    boot_log::trap();
    hal::mmu::init(dtb);
}

/// Phase two: virtual boot.
///
/// Runs after the higher-half mapping is active. Re-installs traps at virtual
/// addresses, expands the physmap to cover all RAM, drops the identity mapping
/// so null dereferences trap, and snapshots hardware info for later subsystems.
pub fn virt_init(dtb: DeviceTreeBlobPhysicalAddress) -> Result<HardwareInfo, BootError> {
    // Trap vectors were installed at a physical address. Re-install them after
    // the higher-half mapping is active.
    hal::trap::init();
    hal::mmu::post_mmu_init();
    crate::console::post_mmu_init();
    boot_log::mmu();

    let hardware = read_hardware_info(dtb)?;
    hal::mmu::expand_physmap(&hardware);
    hal::mmu::remove_identity_mapping();
    boot_log::virt();
    boot_log::dtb(&hardware);
    hal::timer::init_frequency(&hardware);
    Ok(hardware)
}

fn read_hardware_info(dtb: DeviceTreeBlobPhysicalAddress) -> Result<HardwareInfo, BootError> {
    if dtb.get() == 0 {
        return Err(BootError::MissingDeviceTree);
    }

    let blob = DeviceTreeBlob::new(dtb)?;
    let fdt = blob.as_fdt()?;
    Ok(HardwareInfo::from_fdt(dtb, &fdt, blob.data))
}

struct DeviceTreeBlob {
    data: &'static [u8],
}

impl DeviceTreeBlob {
    fn new(dtb: DeviceTreeBlobPhysicalAddress) -> Result<Self, BootError> {
        // Devicetree requires 8-byte blob alignment. `new_unaligned` can read a
        // misaligned slice, but misalignment here usually means bad firmware
        // data or the wrong boot register.
        if !dtb.get().is_multiple_of(8) {
            return Err(BootError::DeviceTreeMisaligned);
        }

        let physical = PhysicalAddress::new(dtb.get());
        let virtual_address = hal::mmu::physical_to_virtual(physical).get();

        // SAFETY: `hal::mmu::init` maps at least DEVICE_TREE_BLOB_MAX_SIZE bytes
        // around the bootloader-provided DTB pointer before this function runs.
        // The first 8 bytes are the FDT magic and totalsize fields. We read
        // those before trusting any header field, so even if firmware handed us
        // a stale pointer to mapped-but-unrelated memory the magic check below
        // rejects it before we slice further.
        let header = unsafe { core::slice::from_raw_parts(virtual_address as *const u8, 8) };
        let magic = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        if magic != FDT_MAGIC {
            return Err(BootError::DeviceTreeMagic);
        }
        let total_size = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
        if total_size > DEVICE_TREE_BLOB_MAX_SIZE {
            return Err(BootError::DeviceTreeTooLarge);
        }

        // SAFETY: The DTB header declares `total_size`, the magic check above
        // confirms it is an FDT, and the early physmap was sized to cover the
        // maximum accepted DTB. The parser validates internal offsets before
        // kernel policy consumes the blob.
        let data = unsafe { core::slice::from_raw_parts(virtual_address as *const u8, total_size) };
        Ok(Self { data })
    }

    fn as_fdt(&self) -> Result<Fdt<'_>, BootError> {
        Fdt::new_unaligned(self.data).map_err(map_fdt_error)
    }
}

fn map_fdt_error(_: FdtError) -> BootError {
    BootError::DeviceTreeHeader
}
