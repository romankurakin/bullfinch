pub mod address;
pub mod page_table_entry;

pub use address::{PAGE_SIZE, PageAligned, PageCount, PageOffset, PhysicalAddress, VirtualAddress};
pub use page_table_entry::{
    MapError, MappingIntent, MappingPermissions, MappingSize, MemoryKind, UnmapError,
};

/// Current boot mappings reserve the first GiB for device access.
pub const BOOT_DEVICE_WINDOW_END: PhysicalAddress =
    PhysicalAddress::new(MappingSize::Block1G.bytes());

/// Reports whether a nonempty region overlaps the current boot device window.
pub fn overlaps_boot_device_window(base: PhysicalAddress, size: usize) -> bool {
    size != 0 && base < BOOT_DEVICE_WINDOW_END
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boot_device_window_rejects_nonempty_overlaps() {
        let end = BOOT_DEVICE_WINDOW_END.get();
        for (base, size) in [(0, 1), (0x1000_0000, 0x2000), (end - 1, 1), (end - 1, 2)] {
            assert!(overlaps_boot_device_window(
                PhysicalAddress::new(base),
                size
            ));
        }
    }

    #[test]
    fn boot_device_window_accepts_empty_and_disjoint_regions() {
        let end = BOOT_DEVICE_WINDOW_END.get();
        for (base, size) in [(0, 0), (end - 1, 0), (end, 1), (end + 1, 0x1000)] {
            assert!(!overlaps_boot_device_window(
                PhysicalAddress::new(base),
                size
            ));
        }
    }
}
