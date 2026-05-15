//! Architecture-neutral mapping intent.
//!
//! Page-table descriptor bits differ between ARM64 and RISC-V. Portable code
//! should describe what it wants (address, size, permissions, memory type) and
//! let the architecture module translate that intent into the correct bits.

use super::address::{PAGE_SIZE, PageAligned, PhysicalAddress};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MapError {
    NotAligned,
    NotCanonical,
    TableNotPresent,
    AlreadyMapped,
    SuperpageConflict,
    OutOfMemory,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UnmapError {
    NotCanonical,
    NotMapped,
    SuperpageConflict,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MemoryKind {
    Normal,
    Device,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MappingSize {
    Page4K,
    Block2M,
    Block1G,
}

impl MappingSize {
    pub const fn bytes(self) -> usize {
        match self {
            Self::Page4K => PAGE_SIZE,
            Self::Block2M => 1 << 21,
            Self::Block1G => 1 << 30,
        }
    }

    pub const fn is_aligned(self, address: PhysicalAddress) -> bool {
        address.get() & (self.bytes() - 1) == 0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MappingPermissions {
    pub writable: bool,
    pub executable: bool,
    pub user_accessible: bool,
}

impl MappingPermissions {
    pub const KERNEL_READ_WRITE: Self = Self {
        writable: true,
        executable: false,
        user_accessible: false,
    };

    pub const KERNEL_READ_EXECUTE: Self = Self {
        writable: false,
        executable: true,
        user_accessible: false,
    };

    pub const USER_READ_WRITE: Self = Self {
        writable: true,
        executable: false,
        user_accessible: true,
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MappingIntent {
    pub physical_address: PageAligned<PhysicalAddress>,
    pub size: MappingSize,
    pub memory: MemoryKind,
    pub permissions: MappingPermissions,
}

impl MappingIntent {
    pub fn new(
        physical_address: PhysicalAddress,
        size: MappingSize,
        memory: MemoryKind,
        permissions: MappingPermissions,
    ) -> Option<Self> {
        let physical_address = PageAligned::<PhysicalAddress>::new(physical_address)?;
        size.is_aligned(physical_address.get()).then_some(Self {
            physical_address,
            size,
            memory,
            permissions,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_page_aligned_mappings() {
        let intent = MappingIntent::new(
            PhysicalAddress::new(0x4000),
            MappingSize::Page4K,
            MemoryKind::Normal,
            MappingPermissions::KERNEL_READ_WRITE,
        )
        .unwrap();

        assert_eq!(intent.physical_address.get(), PhysicalAddress::new(0x4000));
        assert_eq!(intent.size.bytes(), PAGE_SIZE);
    }

    #[test]
    fn rejects_misaligned_mappings_for_size() {
        assert_eq!(
            MappingIntent::new(
                PhysicalAddress::new(0x4001),
                MappingSize::Page4K,
                MemoryKind::Normal,
                MappingPermissions::KERNEL_READ_WRITE,
            ),
            None
        );
        assert_eq!(
            MappingIntent::new(
                PhysicalAddress::new(0x20_0000),
                MappingSize::Block1G,
                MemoryKind::Normal,
                MappingPermissions::KERNEL_READ_WRITE,
            ),
            None
        );
    }
}
