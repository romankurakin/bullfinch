//! Two-phase kernel boot.
//!
//! Boot starts with the MMU off. The physical phase builds the initial page
//! tables, including a mapping for the firmware-provided DTB address. The
//! kernel then enters the higher half of its virtual address space.
//! The virtual phase reads the DTB and expands the physmap, the kernel's
//! mapping of physical memory, to cover the discovered RAM.

use kernel::{
    boot::DeviceTreeBlobPhysicalAddress,
    fdt::{Fdt, FdtError},
    hwinfo::HardwareInfo,
    limits::DEVICE_TREE_BLOB_MAX_SIZE,
    mmu::{MapError, PhysicalAddress},
};

use crate::{hal, startup::log as boot_log};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootError {
    MissingDeviceTree,
    DeviceTree(FdtError),
    DeviceTreeTooLarge,
    DeviceTreeMagic,
    DeviceTreeMisaligned,
    DeviceTreeAddressNotMapped,
    MemoryMap(MapError),
}

impl From<FdtError> for BootError {
    fn from(error: FdtError) -> Self {
        Self::DeviceTree(error)
    }
}

impl From<MapError> for BootError {
    fn from(error: MapError) -> Self {
        Self::MemoryMap(error)
    }
}

/// Magic value at byte offset 0 of every flat device-tree blob.
/// See "Devicetree Specification", section 5.2 (Header).
const FDT_MAGIC: u32 = 0xd00d_feed;

/// Phase one: physical boot.
///
/// Runs with the MMU off. It installs trap vectors and builds the initial page
/// tables. DTB parsing waits until the virtual phase can use those mappings.
pub fn phys_init(dtb: DeviceTreeBlobPhysicalAddress) -> Result<(), BootError> {
    boot_log::header();
    boot_log::uart();
    hal::trap::init();
    boot_log::trap();
    hal::mmu::init(dtb)?;
    Ok(())
}

/// Phase two: virtual boot.
///
/// Runs after the higher-half mapping is active. It reinstalls trap vectors
/// at virtual addresses and reads hardware information from the DTB.
/// It then expands the physmap and removes the identity mapping, where virtual
/// and physical addresses are equal. Removing that mapping leaves the lower
/// address range unmapped, so null dereferences fault.
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
    let hardware = HardwareInfo::from_fdt(dtb, &fdt)?;
    Ok(hardware)
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
        let virtual_address = hal::mmu::try_physical_to_virtual(physical)
            .ok_or(BootError::DeviceTreeAddressNotMapped)?
            .get();

        // SAFETY: `hal::mmu::init` already mapped DEVICE_TREE_BLOB_MAX_SIZE bytes
        // from the bootloader-provided DTB address. This read covers only the
        // first 8 bytes: magic and totalsize. The magic check rejects mapped
        // memory without an FDT signature before we read a larger slice.
        let header = unsafe { core::slice::from_raw_parts(virtual_address as *const u8, 8) };
        let magic = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        if magic != FDT_MAGIC {
            return Err(BootError::DeviceTreeMagic);
        }
        let total_size = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
        if total_size > DEVICE_TREE_BLOB_MAX_SIZE {
            return Err(BootError::DeviceTreeTooLarge);
        }

        // SAFETY: The header passed the magic check, and `total_size` is within
        // the limit checked above. The early physmap covers that maximum size.
        // The parser validates internal offsets before kernel code uses them.
        let data = unsafe { core::slice::from_raw_parts(virtual_address as *const u8, total_size) };
        Ok(Self { data })
    }

    fn as_fdt(&self) -> Result<Fdt<'_>, BootError> {
        let fdt = Fdt::new(self.data).map_err(FdtError::from)?;
        Ok(fdt)
    }
}
