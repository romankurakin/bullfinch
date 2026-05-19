//! RISC-V Sv48 memory-management unit.
//!
//! Sv48 uses four 9 bit page table levels. Boot uses 1 GiB gigapages beneath a
//! static root, which avoids allocator use before PMM exists.
//!
//! See RISC-V Privileged Specification, Sections 12.3-12.6 (Virtual Memory).

#![allow(dead_code, reason = "kernel and library builds use different helpers")]

use core::{arch::asm, cell::UnsafeCell};

use kernel::{
    boot::DeviceTreeBlobPhysicalAddress,
    limits::{DEVICE_TREE_BLOB_MAX_SIZE, ENTRIES_PER_PAGE_TABLE, MINIMUM_PHYSMAP_SIZE},
    mmu::{
        MapError, MappingIntent, MappingPermissions, MappingSize, MemoryKind, PAGE_SIZE,
        PhysicalAddress, UnmapError, VirtualAddress,
    },
};

use super::cpu;

/// Higher-half base. Sv48 canonical upper half starts here.
pub const KERNEL_VIRTUAL_BASE: usize = 0xffff_8000_0000_0000;

/// Physical load address chosen by the linker script for QEMU virt.
pub const KERNEL_PHYSICAL_LOAD: usize = 0x8020_0000;

const PAGE_SHIFT: usize = PAGE_SIZE.trailing_zeros() as usize;
const GIGAPAGE: usize = 1 << 30;
const GIGAPAGE_MASK: usize = GIGAPAGE - 1;
const MEGAPAGE: usize = 1 << 21;
const MEGAPAGE_MASK: usize = MEGAPAGE - 1;

const LOWER_CANONICAL_LIMIT: usize = 1 << 47;

// Sv48 VPN3 covers bits [47:39]. For KERNEL_VIRTUAL_BASE this is 0x1ff.
const KERNEL_VPN3: usize = (KERNEL_VIRTUAL_BASE >> 39) & 0x1ff;
const MAX_PHYSMAP_ENTRIES: usize = ENTRIES_PER_PAGE_TABLE - 1;
const MAX_BOOT_GIGAPAGES: usize = ENTRIES_PER_PAGE_TABLE;
pub const KERNEL_STACK_REGION_OFFSET: usize = (ENTRIES_PER_PAGE_TABLE - 1) * GIGAPAGE;

pub type PageTableAllocator = fn() -> Option<VirtualAddress>;

static ROOT_TABLE: BootPageTable = BootPageTable::empty();
static IDENTITY_L2_TABLE: BootPageTable = BootPageTable::empty();
static PHYSMAP_L2_TABLE: BootPageTable = BootPageTable::empty();
static PHYSMAP_END_GB: BootCounter = BootCounter::new(0);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PageTableEntry(u64);

impl PageTableEntry {
    const VALID: u64 = 1 << 0;
    const READABLE: u64 = 1 << 1;
    const WRITABLE: u64 = 1 << 2;
    const EXECUTABLE: u64 = 1 << 3;
    const USER: u64 = 1 << 4;
    const GLOBAL: u64 = 1 << 5;
    const ACCESSED: u64 = 1 << 6;
    const DIRTY: u64 = 1 << 7;
    const PHYSICAL_PAGE_NUMBER_SHIFT: u64 = 10;

    pub const INVALID: Self = Self(0);

    pub const fn raw(self) -> u64 {
        self.0
    }

    pub const fn is_valid(self) -> bool {
        self.0 & Self::VALID != 0
    }

    pub const fn is_leaf(self) -> bool {
        self.0 & (Self::READABLE | Self::WRITABLE | Self::EXECUTABLE) != 0
    }

    pub const fn is_branch(self) -> bool {
        self.is_valid() && !self.is_leaf()
    }

    pub fn output_address(self) -> Option<PhysicalAddress> {
        self.is_valid().then(|| {
            PhysicalAddress::new(
                ((self.0 >> Self::PHYSICAL_PAGE_NUMBER_SHIFT) as usize) << PAGE_SHIFT,
            )
        })
    }

    pub fn branch(table: PhysicalAddress) -> Option<Self> {
        Some(Self(Self::VALID | physical_page_number(table)?))
    }

    pub fn from_mapping(intent: MappingIntent) -> Self {
        let mut value = Self::VALID
            | Self::READABLE
            | Self::ACCESSED
            | physical_page_number(intent.physical_address.get()).expect("validated mapping");
        apply_permissions(&mut value, intent.permissions);
        Self(value)
    }
}

#[repr(C, align(4096))]
pub struct PageTable {
    entries: [PageTableEntry; ENTRIES_PER_PAGE_TABLE],
}

impl PageTable {
    pub const fn empty() -> Self {
        Self {
            entries: [PageTableEntry::INVALID; ENTRIES_PER_PAGE_TABLE],
        }
    }
}

struct BootPageTable(UnsafeCell<PageTable>);

// SAFETY: Boot page tables are mutated only during single-hart early boot or
// through MMU functions that own the required ordering and TLB maintenance.
// TODO(smp): once secondary harts come online, every mutation path through
// these tables must hold a lock and shoot down remote TLBs. This impl will no
// longer be sound as-is.
unsafe impl Sync for BootPageTable {}

impl BootPageTable {
    const fn empty() -> Self {
        Self(UnsafeCell::new(PageTable::empty()))
    }

    fn get(&self) -> *mut PageTable {
        self.0.get()
    }
}

struct BootCounter(UnsafeCell<usize>);

// SAFETY: This value is updated only while boot is single-hart. SMP support
// must replace this with locked state and remote sfence shootdown.
unsafe impl Sync for BootCounter {}

impl BootCounter {
    const fn new(value: usize) -> Self {
        Self(UnsafeCell::new(value))
    }

    fn get(&self) -> usize {
        // SAFETY: Reads are ordered by the boot flow. There are no concurrent
        // writers before SMP exists.
        unsafe { *self.0.get() }
    }

    fn set(&self, value: usize) {
        // SAFETY: Writes happen only during single-hart boot.
        unsafe {
            *self.0.get() = value;
        }
    }
}

pub fn physical_to_virtual(address: PhysicalAddress) -> VirtualAddress {
    VirtualAddress::new(address.get().wrapping_add(KERNEL_VIRTUAL_BASE))
}

pub fn virtual_to_physical(address: VirtualAddress) -> PhysicalAddress {
    PhysicalAddress::new(address.get().wrapping_sub(KERNEL_VIRTUAL_BASE))
}

pub const fn kernel_stack_region_base() -> VirtualAddress {
    VirtualAddress::new(KERNEL_VIRTUAL_BASE + KERNEL_STACK_REGION_OFFSET)
}

pub fn init(kernel_load: PhysicalAddress, dtb: DeviceTreeBlobPhysicalAddress) {
    let map_start = if dtb.get() == 0 {
        kernel_load.get()
    } else {
        core::cmp::min(kernel_load.get(), dtb.get())
    };
    let dtb_end = if dtb.get() == 0 {
        kernel_load.get()
    } else {
        dtb.get().saturating_add(DEVICE_TREE_BLOB_MAX_SIZE)
    };
    let map_end = core::cmp::max(
        kernel_load.get().saturating_add(MINIMUM_PHYSMAP_SIZE),
        dtb_end,
    );
    let start_gb = map_start / GIGAPAGE;
    let end_gb = map_end.div_ceil(GIGAPAGE);
    validate_boot_range(start_gb, end_gb);

    // SAFETY: Early boot is single-hart. These static tables are exclusively
    // initialized here before interrupts are enabled.
    unsafe {
        let root =
            &mut *(static_physical_address(ROOT_TABLE.get().cast_const()).get() as *mut PageTable);
        let identity = &mut *(static_physical_address(IDENTITY_L2_TABLE.get().cast_const()).get()
            as *mut PageTable);
        let physmap = &mut *(static_physical_address(PHYSMAP_L2_TABLE.get().cast_const()).get()
            as *mut PageTable);
        root.entries.fill(PageTableEntry::INVALID);
        identity.entries.fill(PageTableEntry::INVALID);
        physmap.entries.fill(PageTableEntry::INVALID);

        identity.entries[0] = kernel_leaf(PhysicalAddress::ZERO, false);
        physmap.entries[0] = kernel_leaf(PhysicalAddress::ZERO, false);
        for gb in start_gb..end_gb {
            if gb == 0 {
                continue;
            }
            let address = PhysicalAddress::new(gb * GIGAPAGE);
            identity.entries[gb] = kernel_leaf(address, true);
            physmap.entries[gb] = kernel_leaf(address, true);
        }
        root.entries[0] = PageTableEntry::branch(static_physical_address(
            IDENTITY_L2_TABLE.get().cast_const(),
        ))
        .expect("identity table is page aligned");
        root.entries[KERNEL_VPN3] =
            PageTableEntry::branch(static_physical_address(PHYSMAP_L2_TABLE.get().cast_const()))
                .expect("physmap table is page aligned");
        PHYSMAP_END_GB.set(end_gb);

        cpu::fence_rw_rw();
        write_satp(SupervisorAddressTranslation::sv48(
            static_physical_address(ROOT_TABLE.get().cast_const()),
            0,
        ));
    }

    TranslationLookasideBuffer::flush_all();
}

pub fn post_mmu_init() {
    // SAFETY: GP was established at a physical address. Reload it after the
    // higher-half mapping is live.
    unsafe {
        asm!(
            ".option push",
            ".option norelax",
            "la gp, __global_pointer$",
            ".option pop",
            options(nostack, preserves_flags)
        );
    }
}

pub fn expand_physmap(max_end: PhysicalAddress) {
    let new_end = core::cmp::min(max_end.get().div_ceil(GIGAPAGE), MAX_PHYSMAP_ENTRIES);

    let current = PHYSMAP_END_GB.get();
    // SAFETY: Called during single-hart boot before SMP exists.
    // TODO(smp): once secondary harts come online, expand under a lock and
    // issue cross-hart sfence shootdown.
    unsafe {
        let physmap = &mut *PHYSMAP_L2_TABLE.get();
        for gb in current..new_end {
            if gb == 0 {
                continue;
            }
            physmap.entries[gb] = kernel_leaf(PhysicalAddress::new(gb * GIGAPAGE), true);
        }
    }
    if new_end > current {
        PHYSMAP_END_GB.set(new_end);
        TranslationLookasideBuffer::flush_all();
    }
}

pub fn remove_identity_mapping() {
    // SAFETY: The kernel is executing through the higher-half root entry by the
    // time `virt_init` removes the lower-half branch.
    unsafe {
        (*ROOT_TABLE.get()).entries[0] = PageTableEntry::INVALID;
    }
    TranslationLookasideBuffer::flush_all();
}

/// Translates a virtual address through a RISC-V Sv48 page table tree.
///
/// # Safety
///
/// `root` and every branch descriptor reachable from it must point to valid
/// page table pages mapped in the kernel physmap. The caller must prevent
/// concurrent mutation of that tree for the duration of the walk.
pub unsafe fn translate(root: &PageTable, address: VirtualAddress) -> Option<PhysicalAddress> {
    if !is_canonical(address) {
        return None;
    }

    let vpn3 = (address.get() >> 39) & 0x1ff;
    let vpn2 = (address.get() >> 30) & 0x1ff;
    let vpn1 = (address.get() >> 21) & 0x1ff;
    let vpn0 = (address.get() >> 12) & 0x1ff;

    let entry = root.entries[vpn3];
    if !entry.is_valid() {
        return None;
    }
    if entry.is_leaf() {
        return entry
            .output_address()?
            .checked_add(address.get() & ((1 << 39) - 1));
    }

    let table = table_from_physical(entry.output_address()?);
    // SAFETY: A valid branch entry points to a page table page owned by the MMU.
    let entry = unsafe { (*table).entries[vpn2] };
    if !entry.is_valid() {
        return None;
    }
    if entry.is_leaf() {
        return entry
            .output_address()?
            .checked_add(address.get() & GIGAPAGE_MASK);
    }

    let table = table_from_physical(entry.output_address()?);
    // SAFETY: A valid branch entry points to a page table page owned by the MMU.
    let entry = unsafe { (*table).entries[vpn1] };
    if !entry.is_valid() {
        return None;
    }
    if entry.is_leaf() {
        return entry
            .output_address()?
            .checked_add(address.get() & MEGAPAGE_MASK);
    }

    let table = table_from_physical(entry.output_address()?);
    // SAFETY: A valid branch entry points to a page table page owned by the MMU.
    let entry = unsafe { (*table).entries[vpn0] };
    entry
        .is_valid()
        .then(|| {
            entry
                .output_address()?
                .checked_add(address.page_offset().get())
        })
        .flatten()
}

/// Installs one 4 KiB leaf mapping in an existing Sv48 page table tree.
///
/// # Safety
///
/// `root` and every branch descriptor used by this mapping must belong to a
/// valid page table tree owned by the caller. The caller must have exclusive
/// mutation rights to the tree and must coordinate with any address-space or
/// remote-sfence users not covered by the local invalidation here.
pub unsafe fn map_page(
    root: &mut PageTable,
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    permissions: MappingPermissions,
) -> Result<(), MapError> {
    if !virtual_address.is_page_aligned() || !physical_address.is_page_aligned() {
        return Err(MapError::NotAligned);
    }
    if !is_canonical(virtual_address) {
        return Err(MapError::NotCanonical);
    }

    let vpn3 = (virtual_address.get() >> 39) & 0x1ff;
    let vpn2 = (virtual_address.get() >> 30) & 0x1ff;
    let vpn1 = (virtual_address.get() >> 21) & 0x1ff;
    let vpn0 = (virtual_address.get() >> 12) & 0x1ff;
    let l3 = root.entries[vpn3];
    if !l3.is_branch() {
        return Err(if l3.is_valid() {
            MapError::SuperpageConflict
        } else {
            MapError::TableNotPresent
        });
    }
    let l2_table = table_from_physical(l3.output_address().unwrap());
    // SAFETY: L3 was validated as a branch entry.
    let l2 = unsafe { (*l2_table).entries[vpn2] };
    if !l2.is_branch() {
        return Err(if l2.is_valid() {
            MapError::SuperpageConflict
        } else {
            MapError::TableNotPresent
        });
    }
    let l1_table = table_from_physical(l2.output_address().unwrap());
    // SAFETY: L2 was validated as a branch entry.
    let l1 = unsafe { (*l1_table).entries[vpn1] };
    if !l1.is_branch() {
        return Err(if l1.is_valid() {
            MapError::SuperpageConflict
        } else {
            MapError::TableNotPresent
        });
    }
    let l0_table = table_from_physical(l1.output_address().unwrap());
    // SAFETY: L1 was validated as a branch entry.
    let slot = unsafe { &mut (*l0_table).entries[vpn0] };
    if slot.is_valid() {
        return Err(MapError::AlreadyMapped);
    }
    *slot = PageTableEntry::from_mapping(
        MappingIntent::new(
            physical_address,
            MappingSize::Page4K,
            MemoryKind::Normal,
            permissions,
        )
        .ok_or(MapError::NotAligned)?,
    );
    // RISC-V may keep using the old translation state until SFENCE.VMA.
    TranslationLookasideBuffer::flush_address(virtual_address);
    Ok(())
}

pub fn map_kernel_page_with_alloc(
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    permissions: MappingPermissions,
    allocate_table: PageTableAllocator,
) -> Result<(), MapError> {
    // SAFETY: The root table is the active kernel owned table. Boot is still
    // single-hart while stack slots are created in the current rung.
    unsafe {
        map_page_with_alloc(
            &mut *ROOT_TABLE.get(),
            virtual_address,
            physical_address,
            permissions,
            allocate_table,
        )
    }
}

/// Installs one 4 KiB leaf mapping, allocating missing Sv48 branch tables.
///
/// # Safety
///
/// `root` must be a valid kernel owned Sv48 root. The caller must hold the
/// page table mutation lock once SMP exists, and `allocate_table` must return a
/// zeroed, page-aligned table page mapped in the kernel physmap.
unsafe fn map_page_with_alloc(
    root: &mut PageTable,
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    permissions: MappingPermissions,
    allocate_table: PageTableAllocator,
) -> Result<(), MapError> {
    if !virtual_address.is_page_aligned() || !physical_address.is_page_aligned() {
        return Err(MapError::NotAligned);
    }
    if !is_canonical(virtual_address) {
        return Err(MapError::NotCanonical);
    }

    let vpn3 = (virtual_address.get() >> 39) & 0x1ff;
    let vpn2 = (virtual_address.get() >> 30) & 0x1ff;
    let vpn1 = (virtual_address.get() >> 21) & 0x1ff;
    let vpn0 = (virtual_address.get() >> 12) & 0x1ff;

    let l3 = &mut root.entries[vpn3];
    if !l3.is_valid() {
        let next = allocate_table().ok_or(MapError::OutOfMemory)?;
        *l3 = PageTableEntry::branch(virtual_to_physical(next)).ok_or(MapError::NotAligned)?;
    } else if !l3.is_branch() {
        return Err(MapError::SuperpageConflict);
    }

    let l2_table = table_from_physical(l3.output_address().unwrap());
    // SAFETY: L3 was validated as a branch entry.
    let l2 = unsafe { &mut (*l2_table).entries[vpn2] };
    if !l2.is_valid() {
        let next = allocate_table().ok_or(MapError::OutOfMemory)?;
        *l2 = PageTableEntry::branch(virtual_to_physical(next)).ok_or(MapError::NotAligned)?;
    } else if !l2.is_branch() {
        return Err(MapError::SuperpageConflict);
    }

    let l1_table = table_from_physical(l2.output_address().unwrap());
    // SAFETY: L2 was validated as a branch entry.
    let l1 = unsafe { &mut (*l1_table).entries[vpn1] };
    if !l1.is_valid() {
        let next = allocate_table().ok_or(MapError::OutOfMemory)?;
        *l1 = PageTableEntry::branch(virtual_to_physical(next)).ok_or(MapError::NotAligned)?;
    } else if !l1.is_branch() {
        return Err(MapError::SuperpageConflict);
    }

    let l0_table = table_from_physical(l1.output_address().unwrap());
    // SAFETY: L1 was validated as a branch entry.
    let slot = unsafe { &mut (*l0_table).entries[vpn0] };
    if slot.is_valid() {
        return Err(MapError::AlreadyMapped);
    }
    *slot = PageTableEntry::from_mapping(
        MappingIntent::new(
            physical_address,
            MappingSize::Page4K,
            MemoryKind::Normal,
            permissions,
        )
        .ok_or(MapError::NotAligned)?,
    );
    TranslationLookasideBuffer::flush_address(virtual_address);
    Ok(())
}

pub fn unmap_kernel_page(virtual_address: VirtualAddress) -> Result<PhysicalAddress, UnmapError> {
    // SAFETY: The root table is the active kernel owned table. Stack teardown
    // runs before SMP page table sharing exists.
    unsafe { unmap_page(&mut *ROOT_TABLE.get(), virtual_address) }
}

/// Removes one 4 KiB leaf mapping from an existing Sv48 page table tree.
///
/// # Safety
///
/// `root` and every branch descriptor used by this mapping must belong to a
/// valid page table tree owned by the caller. The caller must have exclusive
/// mutation rights to the tree and must not free the physical page until all
/// harts that could use the old translation have observed the sfence.
pub unsafe fn unmap_page(
    root: &mut PageTable,
    virtual_address: VirtualAddress,
) -> Result<PhysicalAddress, UnmapError> {
    if !is_canonical(virtual_address) {
        return Err(UnmapError::NotCanonical);
    }

    let vpn3 = (virtual_address.get() >> 39) & 0x1ff;
    let vpn2 = (virtual_address.get() >> 30) & 0x1ff;
    let vpn1 = (virtual_address.get() >> 21) & 0x1ff;
    let vpn0 = (virtual_address.get() >> 12) & 0x1ff;
    let l3 = root.entries[vpn3];
    if !l3.is_branch() {
        return Err(if l3.is_valid() {
            UnmapError::SuperpageConflict
        } else {
            UnmapError::NotMapped
        });
    }
    let l2_table = table_from_physical(l3.output_address().unwrap());
    // SAFETY: L3 was validated as a branch entry.
    let l2 = unsafe { (*l2_table).entries[vpn2] };
    if !l2.is_branch() {
        return Err(if l2.is_valid() {
            UnmapError::SuperpageConflict
        } else {
            UnmapError::NotMapped
        });
    }
    let l1_table = table_from_physical(l2.output_address().unwrap());
    // SAFETY: L2 was validated as a branch entry.
    let l1 = unsafe { (*l1_table).entries[vpn1] };
    if !l1.is_branch() {
        return Err(if l1.is_valid() {
            UnmapError::SuperpageConflict
        } else {
            UnmapError::NotMapped
        });
    }
    let l0_table = table_from_physical(l1.output_address().unwrap());
    // SAFETY: L1 was validated as a branch entry.
    let slot = unsafe { &mut (*l0_table).entries[vpn0] };
    if !slot.is_valid() {
        return Err(UnmapError::NotMapped);
    }
    let physical = slot.output_address().ok_or(UnmapError::NotMapped)?;
    *slot = PageTableEntry::INVALID;
    // The invalid PTE must be ordered before later translations of this page.
    cpu::fence_rw_rw();
    TranslationLookasideBuffer::flush_address(virtual_address);
    Ok(physical)
}

pub struct TranslationLookasideBuffer;

impl TranslationLookasideBuffer {
    pub fn flush_all() {
        cpu::fence_rw_rw();
        // SAFETY: RISC-V does not order page table writes with address
        // translation by itself. SFENCE.VMA is the architectural handoff.
        unsafe { asm!("sfence.vma zero, zero", options(nostack, preserves_flags)) };
    }

    pub fn flush_address(address: VirtualAddress) {
        cpu::fence_rw_rw();
        // SAFETY: The address-scoped form orders writes for one local page. Remote
        // shootdown belongs to the later SMP rung.
        //
        // NOTE: Per the RISC-V Privileged Spec (section 4.2.1), an implementation
        // is permitted to skip global PTEs when given the address-scoped form
        // with ASID=zero. Boot mappings are GLOBAL, so any unmap path that hits
        // a kernel-global page must use `flush_all` instead. Today the only
        // mappings that exist are kernel-global, so `unmap_page` is unreachable;
        // when user mappings land this will need to branch on globality.
        // TODO(user-mappings): once non-global PTEs exist, pick scope by PTE.
        unsafe {
            asm!(
                "sfence.vma {address}, zero",
                address = in(reg) address.get(),
                options(nostack, preserves_flags)
            );
        }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy)]
struct SupervisorAddressTranslation(u64);

impl SupervisorAddressTranslation {
    const MODE_SV48: u64 = 9;

    fn sv48(root: PhysicalAddress, asid: u16) -> Self {
        Self(
            (Self::MODE_SV48 << 60) | (u64::from(asid) << 44) | ((root.get() >> PAGE_SHIFT) as u64),
        )
    }
}

fn write_satp(value: SupervisorAddressTranslation) {
    // SAFETY: SATP is written after the root table is initialized. The caller
    // immediately executes SFENCE.VMA.
    unsafe {
        asm!("csrw satp, {value}", value = in(reg) value.0, options(nostack, preserves_flags))
    };
}

fn is_canonical(address: VirtualAddress) -> bool {
    address.get() < LOWER_CANONICAL_LIMIT || address.get() >= KERNEL_VIRTUAL_BASE
}

fn table_from_physical(address: PhysicalAddress) -> *mut PageTable {
    physical_to_virtual(address).get() as *mut PageTable
}

fn static_physical_address<T>(ptr: *const T) -> PhysicalAddress {
    let raw = ptr as usize;
    if raw >= KERNEL_VIRTUAL_BASE {
        virtual_to_physical(VirtualAddress::new(raw))
    } else {
        PhysicalAddress::new(raw)
    }
}

fn kernel_leaf(address: PhysicalAddress, executable: bool) -> PageTableEntry {
    PageTableEntry::from_mapping(
        MappingIntent::new(
            address,
            MappingSize::Block1G,
            MemoryKind::Normal,
            MappingPermissions {
                writable: true,
                executable,
                user_accessible: false,
            },
        )
        .expect("boot gigapage is aligned"),
    )
}

fn apply_permissions(value: &mut u64, permissions: MappingPermissions) {
    if permissions.writable {
        *value |= PageTableEntry::WRITABLE | PageTableEntry::DIRTY;
    }
    if permissions.executable {
        *value |= PageTableEntry::EXECUTABLE;
    }
    if permissions.user_accessible {
        *value |= PageTableEntry::USER;
    } else {
        *value |= PageTableEntry::GLOBAL;
    }
}

fn physical_page_number(address: PhysicalAddress) -> Option<u64> {
    address.is_page_aligned().then_some(
        ((address.get() >> PAGE_SHIFT) as u64) << PageTableEntry::PHYSICAL_PAGE_NUMBER_SHIFT,
    )
}

fn validate_boot_range(start_gb: usize, end_gb: usize) {
    if start_gb > end_gb || end_gb > MAX_BOOT_GIGAPAGES {
        panic!("mmu: boot physical range exceeds RISC-V boot page table");
    }
}

const _: () = assert!(core::mem::size_of::<PageTableEntry>() == 8);
const _: () = assert!(core::mem::size_of::<PageTable>() == PAGE_SIZE);
