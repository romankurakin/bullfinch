//! Address and page-count types.
//!
//! Physical addresses, virtual addresses, and byte offsets are all just
//! integers to the hardware. Mixing them up is a common MMU bug. These
//! newtypes are zero-cost wrappers that let the type checker catch swaps at
//! build time. `PageAligned<A>` is a proof that `A` is page-aligned.

pub const PAGE_SIZE: usize = 4096;
const PAGE_MASK: usize = PAGE_SIZE - 1;

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd)]
pub struct PhysicalAddress(usize);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd)]
pub struct VirtualAddress(usize);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd)]
pub struct PageCount(usize);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd)]
pub struct PageOffset(usize);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PageAligned<A> {
    addr: A,
}

impl PhysicalAddress {
    pub const ZERO: Self = Self(0);

    pub const fn new(raw: usize) -> Self {
        Self(raw)
    }

    pub fn try_from_u64(raw: u64) -> Option<Self> {
        usize::try_from(raw).ok().map(Self)
    }

    pub const fn get(self) -> usize {
        self.0
    }

    pub const fn page_offset(self) -> PageOffset {
        PageOffset(self.0 & PAGE_MASK)
    }

    pub const fn is_page_aligned(self) -> bool {
        self.page_offset().get() == 0
    }

    pub fn checked_add(self, bytes: usize) -> Option<Self> {
        self.0.checked_add(bytes).map(Self)
    }

    pub const fn align_down(self) -> PageAligned<Self> {
        PageAligned {
            addr: Self(self.0 & !PAGE_MASK),
        }
    }

    pub fn align_up(self) -> Option<PageAligned<Self>> {
        let rounded = self.0.checked_add(PAGE_MASK)? & !PAGE_MASK;
        Some(PageAligned {
            addr: Self(rounded),
        })
    }
}

impl VirtualAddress {
    pub const ZERO: Self = Self(0);

    pub const fn new(raw: usize) -> Self {
        Self(raw)
    }

    pub const fn get(self) -> usize {
        self.0
    }

    pub const fn page_offset(self) -> PageOffset {
        PageOffset(self.0 & PAGE_MASK)
    }

    pub const fn is_page_aligned(self) -> bool {
        self.page_offset().get() == 0
    }

    pub fn checked_add(self, bytes: usize) -> Option<Self> {
        self.0.checked_add(bytes).map(Self)
    }

    pub const fn align_down(self) -> PageAligned<Self> {
        PageAligned {
            addr: Self(self.0 & !PAGE_MASK),
        }
    }

    pub fn align_up(self) -> Option<PageAligned<Self>> {
        let rounded = self.0.checked_add(PAGE_MASK)? & !PAGE_MASK;
        Some(PageAligned {
            addr: Self(rounded),
        })
    }
}

impl PageCount {
    pub const ZERO: Self = Self(0);

    pub const fn new(raw: usize) -> Self {
        Self(raw)
    }

    pub const fn get(self) -> usize {
        self.0
    }

    pub fn from_bytes_round_up(bytes: usize) -> Option<Self> {
        bytes
            .checked_add(PAGE_MASK)
            .map(|value| Self(value / PAGE_SIZE))
    }

    pub fn to_bytes(self) -> Option<usize> {
        self.0.checked_mul(PAGE_SIZE)
    }
}

impl PageOffset {
    pub const ZERO: Self = Self(0);

    pub const fn new(raw: usize) -> Option<Self> {
        if raw < PAGE_SIZE {
            Some(Self(raw))
        } else {
            None
        }
    }

    pub const fn get(self) -> usize {
        self.0
    }
}

impl<A> PageAligned<A> {
    pub fn get(self) -> A {
        self.addr
    }
}

impl PageAligned<PhysicalAddress> {
    pub const fn new(addr: PhysicalAddress) -> Option<Self> {
        if addr.is_page_aligned() {
            Some(Self { addr })
        } else {
            None
        }
    }
}

impl PageAligned<VirtualAddress> {
    pub const fn new(addr: VirtualAddress) -> Option<Self> {
        if addr.is_page_aligned() {
            Some(Self { addr })
        } else {
            None
        }
    }
}

const _: () = assert!(core::mem::size_of::<PhysicalAddress>() == core::mem::size_of::<usize>());
const _: () = assert!(core::mem::size_of::<VirtualAddress>() == core::mem::size_of::<usize>());
const _: () = assert!(core::mem::size_of::<PageCount>() == core::mem::size_of::<usize>());
const _: () = assert!(core::mem::size_of::<PageOffset>() == core::mem::size_of::<usize>());

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracks_page_offsets() {
        assert_eq!(
            PhysicalAddress::new(0x1234).page_offset(),
            PageOffset::new(0x234).unwrap()
        );
        assert_eq!(VirtualAddress::new(0x4000).page_offset(), PageOffset::ZERO);
        assert!(PhysicalAddress::new(0x4000).is_page_aligned());
        assert!(!VirtualAddress::new(0x4001).is_page_aligned());
    }

    #[test]
    fn aligns_addresses() {
        assert_eq!(
            PhysicalAddress::new(0x4123).align_down().get(),
            PhysicalAddress::new(0x4000)
        );
        assert_eq!(
            PhysicalAddress::new(0x4000).align_up().unwrap().get(),
            PhysicalAddress::new(0x4000)
        );
        assert_eq!(
            VirtualAddress::new(0x4001).align_up().unwrap().get(),
            VirtualAddress::new(0x5000)
        );
        assert_eq!(VirtualAddress::new(usize::MAX).align_up(), None);
    }

    #[test]
    fn counts_pages_from_bytes() {
        assert_eq!(PageCount::from_bytes_round_up(0), Some(PageCount::ZERO));
        assert_eq!(PageCount::from_bytes_round_up(1), Some(PageCount::new(1)));
        assert_eq!(
            PageCount::from_bytes_round_up(PAGE_SIZE),
            Some(PageCount::new(1))
        );
        assert_eq!(
            PageCount::from_bytes_round_up(PAGE_SIZE + 1),
            Some(PageCount::new(2))
        );
        assert_eq!(PageCount::new(2).to_bytes(), Some(PAGE_SIZE * 2));
    }

    #[test]
    fn rejects_out_of_range_offsets() {
        assert_eq!(
            PageOffset::new(PAGE_SIZE - 1),
            Some(PageOffset(PAGE_SIZE - 1))
        );
        assert_eq!(PageOffset::new(PAGE_SIZE), None);
    }
}
