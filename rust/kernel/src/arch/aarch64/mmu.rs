//! ARM64 memory-management unit.
//!
//! ARM64 keeps user and kernel address spaces in separate translation-table
//! base registers. Early boot uses 39 bit virtual addresses and 1 GiB blocks,
//! which avoids allocator use before PMM exists.
//!
//! See ARM Architecture Reference Manual, Chapter D8 (The AArch64 Virtual Memory
//! System Architecture).

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

/// Higher-half base. With T0SZ=T1SZ=25 (39 bit VA), TTBR1 covers the top half.
pub const KERNEL_VIRTUAL_BASE: usize = 0xffff_ff80_0000_0000;

/// Physical load address chosen by the linker script for QEMU virt.
pub const KERNEL_PHYSICAL_LOAD: usize = 0x4008_0000;

const PAGE_SHIFT: usize = PAGE_SIZE.trailing_zeros() as usize;
const BLOCK_1G: usize = 1 << 30;
const BLOCK_1G_MASK: usize = BLOCK_1G - 1;
const BLOCK_2M: usize = 1 << 21;
const BLOCK_2M_MASK: usize = BLOCK_2M - 1;
const MAX_PHYSMAP_ENTRIES: usize = ENTRIES_PER_PAGE_TABLE - 1;
const MAX_BOOT_BLOCKS: usize = ENTRIES_PER_PAGE_TABLE;
pub const KERNEL_STACK_REGION_OFFSET: usize = (ENTRIES_PER_PAGE_TABLE - 1) * BLOCK_1G;

pub type PageTableAllocator = fn() -> Option<VirtualAddress>;

// MAIR_EL1 encodes one byte per attribute index. Keep the early slot layout
// broad enough for DMA buffers and MTE without reprogramming MAIR later. Slot 0
// (Device-nGnRnE) backs `MemoryKind::Device`; slot 3 (Normal WBWA) backs
// `MemoryKind::Normal`.
//
// Indices: 0 Device-nGnRnE, 1 Device-nGnRE, 2 Normal NC, 3 Normal WBWA, 4 Normal Tagged.
const MAIR_VALUE: u64 = (0x04 << 8) | (0x44 << 16) | (0xff << 24) | (0xf0 << 32);
const BOOT_KERNEL_PERMISSIONS: MappingPermissions = MappingPermissions {
    writable: true,
    executable: true,
    user_accessible: false,
};

static LOW_TABLE: BootPageTable = BootPageTable::empty();
static HIGH_TABLE: BootPageTable = BootPageTable::empty();
static PHYSMAP_END_GB: BootCounter = BootCounter::new(0);

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PageTableEntry(u64);

impl PageTableEntry {
    const VALID: u64 = 1 << 0;
    const TABLE_OR_PAGE: u64 = 1 << 1;
    const ATTRIBUTE_INDEX_SHIFT: u64 = 2;
    const USER_ACCESSIBLE: u64 = 1 << 6;
    const READ_ONLY: u64 = 1 << 7;
    const OUTER_SHAREABLE: u64 = 0b10 << 8;
    const INNER_SHAREABLE: u64 = 0b11 << 8;
    const ACCESSED: u64 = 1 << 10;
    const NON_GLOBAL: u64 = 1 << 11;
    const PRIVILEGED_EXECUTE_NEVER: u64 = 1 << 53;
    const USER_EXECUTE_NEVER: u64 = 1 << 54;

    pub const INVALID: Self = Self(0);

    pub const fn raw(self) -> u64 {
        self.0
    }

    pub const fn is_valid(self) -> bool {
        self.0 & Self::VALID != 0
    }

    pub const fn is_table(self) -> bool {
        self.is_valid() && self.0 & Self::TABLE_OR_PAGE != 0
    }

    pub const fn is_block(self) -> bool {
        self.is_valid() && self.0 & Self::TABLE_OR_PAGE == 0
    }

    pub fn output_address(self) -> Option<PhysicalAddress> {
        self.is_valid()
            .then(|| PhysicalAddress::new((self.0 as usize) & 0x0000_ffff_ffff_f000))
    }

    pub fn table(next_table: PhysicalAddress) -> Option<Self> {
        Some(Self(
            Self::VALID | Self::TABLE_OR_PAGE | aligned_output_address(next_table)?,
        ))
    }

    pub fn from_mapping(intent: MappingIntent) -> Self {
        match intent.size {
            MappingSize::Page4K => Self::mapping(intent, true),
            MappingSize::Block2M | MappingSize::Block1G => Self::mapping(intent, false),
        }
    }

    fn mapping(intent: MappingIntent, table_or_page: bool) -> Self {
        let attribute = match intent.memory {
            MemoryKind::Device => 0u64,
            MemoryKind::Normal => 3u64,
        };
        let shareability = match intent.memory {
            MemoryKind::Device => Self::OUTER_SHAREABLE,
            MemoryKind::Normal => Self::INNER_SHAREABLE,
        };
        let mut value = Self::VALID
            | Self::ACCESSED
            | shareability
            | aligned_output_address(intent.physical_address.get()).expect("validated mapping")
            | (attribute << Self::ATTRIBUTE_INDEX_SHIFT);
        if table_or_page {
            value |= Self::TABLE_OR_PAGE;
        }
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

// SAFETY: Boot page tables are mutated only during single-core early boot or
// through MMU functions that own the required ordering and TLB maintenance.
// TODO(smp): once secondary cores come online, every mutation path through
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

// SAFETY: This value is updated only during single-core boot. SMP support must
// replace this with locked state and remote TLB shootdown.
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
        // SAFETY: Writes happen only during single-core boot.
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
    write_mair(MAIR_VALUE);
    write_tcr(default_tcr());

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
    let start_gb = map_start / BLOCK_1G;
    let end_gb = map_end.div_ceil(BLOCK_1G);
    validate_boot_range(start_gb, end_gb);

    // SAFETY: Early boot is single-core. These static tables are not exposed
    // through safe aliases while they are being initialized.
    unsafe {
        let low =
            &mut *(static_physical_address(LOW_TABLE.get().cast_const()).get() as *mut PageTable);
        let high =
            &mut *(static_physical_address(HIGH_TABLE.get().cast_const()).get() as *mut PageTable);
        low.entries.fill(PageTableEntry::INVALID);
        high.entries.fill(PageTableEntry::INVALID);

        low.entries[0] = device_block(PhysicalAddress::ZERO);
        high.entries[0] = device_block(PhysicalAddress::ZERO);
        for gb in start_gb..end_gb {
            if gb == 0 {
                continue;
            }
            let address = PhysicalAddress::new(gb * BLOCK_1G);
            low.entries[gb] = kernel_block(address, BOOT_KERNEL_PERMISSIONS);
            high.entries[gb] = kernel_block(address, BOOT_KERNEL_PERMISSIONS);
        }
        PHYSMAP_END_GB.set(end_gb);

        write_ttbr0(static_physical_address(LOW_TABLE.get().cast_const()));
        write_ttbr1(static_physical_address(HIGH_TABLE.get().cast_const()));
    }

    TranslationLookasideBuffer::flush_local();
    enable_mmu();
}

pub fn post_mmu_init() {}

pub fn expand_physmap(max_end: PhysicalAddress) {
    let new_end = core::cmp::min(max_end.get().div_ceil(BLOCK_1G), MAX_PHYSMAP_ENTRIES);

    let current = PHYSMAP_END_GB.get();
    // SAFETY: Called during single-core boot before secondary CPUs exist.
    // TODO(smp): once secondary CPUs come online, expand under a lock and
    // shoot down their TLBs.
    unsafe {
        let high = &mut *HIGH_TABLE.get();
        for gb in current..new_end {
            if gb == 0 {
                continue;
            }
            high.entries[gb] =
                kernel_block(PhysicalAddress::new(gb * BLOCK_1G), BOOT_KERNEL_PERMISSIONS);
        }
    }
    if new_end > current {
        PHYSMAP_END_GB.set(new_end);
        TranslationLookasideBuffer::flush_local();
    }
}

pub fn remove_identity_mapping() {
    // SAFETY: The ARM64 boot stub switches SP and PC into the higher-half
    // mapping before common virtual init calls this function.
    unsafe {
        (*LOW_TABLE.get()).entries.fill(PageTableEntry::INVALID);
    }
    TranslationLookasideBuffer::flush_local();
}

/// Translates a virtual address through an ARM64 page table tree.
///
/// # Safety
///
/// `root` and every table descriptor reachable from it must point to valid
/// page table pages mapped in the kernel physmap. The caller must prevent
/// concurrent mutation of that tree for the duration of the walk.
pub unsafe fn translate(root: &PageTable, address: VirtualAddress) -> Option<PhysicalAddress> {
    if !is_canonical(address) {
        return None;
    }

    let l1 = (address.get() >> 30) & 0x1ff;
    let l2 = (address.get() >> 21) & 0x1ff;
    let l3 = (address.get() >> 12) & 0x1ff;

    let entry = root.entries[l1];
    if !entry.is_valid() {
        return None;
    }
    if entry.is_block() {
        return entry
            .output_address()?
            .checked_add(address.get() & BLOCK_1G_MASK);
    }

    let table = table_from_physical(entry.output_address()?);
    // SAFETY: A valid table entry points to a page table page owned by the MMU.
    let entry = unsafe { (*table).entries[l2] };
    if !entry.is_valid() {
        return None;
    }
    if entry.is_block() {
        return entry
            .output_address()?
            .checked_add(address.get() & BLOCK_2M_MASK);
    }

    let table = table_from_physical(entry.output_address()?);
    // SAFETY: A valid table entry points to a page table page owned by the MMU.
    let entry = unsafe { (*table).entries[l3] };
    entry
        .is_valid()
        .then(|| {
            entry
                .output_address()?
                .checked_add(address.page_offset().get())
        })
        .flatten()
}

/// Installs one 4 KiB leaf mapping in an existing page table tree.
///
/// # Safety
///
/// `root` and every table descriptor used by this mapping must belong to a
/// valid page table tree owned by the caller. The caller must have exclusive
/// mutation rights to the tree and must coordinate with any address-space or
/// remote-TLB users not covered by the local invalidation here.
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

    let l1 = (virtual_address.get() >> 30) & 0x1ff;
    let l2 = (virtual_address.get() >> 21) & 0x1ff;
    let l3 = (virtual_address.get() >> 12) & 0x1ff;
    let l1_entry = root.entries[l1];
    if !l1_entry.is_table() {
        return Err(if l1_entry.is_valid() {
            MapError::SuperpageConflict
        } else {
            MapError::TableNotPresent
        });
    }

    let l2_table = table_from_physical(l1_entry.output_address().unwrap());
    // SAFETY: The L1 table entry was validated as a table descriptor.
    let l2_entry = unsafe { (*l2_table).entries[l2] };
    if !l2_entry.is_table() {
        return Err(if l2_entry.is_valid() {
            MapError::SuperpageConflict
        } else {
            MapError::TableNotPresent
        });
    }

    let l3_table = table_from_physical(l2_entry.output_address().unwrap());
    // SAFETY: The L2 table entry was validated as a table descriptor.
    let slot = unsafe { &mut (*l3_table).entries[l3] };
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
    // A faulting leaf is not cached, but the new descriptor still needs a
    // context synchronization event before code relies on the mapping.
    TranslationLookasideBuffer::flush_address(virtual_address);
    Ok(())
}

pub fn map_kernel_page_with_alloc(
    virtual_address: VirtualAddress,
    physical_address: PhysicalAddress,
    permissions: MappingPermissions,
    allocate_table: PageTableAllocator,
) -> Result<(), MapError> {
    // SAFETY: The high kernel table is the active kernel owned table. Boot is
    // still single-core while stack slots are created in the current rung.
    unsafe {
        map_page_with_alloc(
            &mut *HIGH_TABLE.get(),
            virtual_address,
            physical_address,
            permissions,
            allocate_table,
        )
    }
}

/// Installs one 4 KiB leaf mapping, allocating missing intermediate tables.
///
/// # Safety
///
/// `root` must be a valid kernel owned page table root. The caller must hold
/// the page table mutation lock once SMP exists, and `allocate_table` must
/// return a zeroed, page-aligned table page mapped in the kernel physmap.
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

    let l1 = (virtual_address.get() >> 30) & 0x1ff;
    let l2 = (virtual_address.get() >> 21) & 0x1ff;
    let l3 = (virtual_address.get() >> 12) & 0x1ff;

    let l1_entry = &mut root.entries[l1];
    if !l1_entry.is_valid() {
        let next = allocate_table().ok_or(MapError::OutOfMemory)?;
        *l1_entry = PageTableEntry::table(virtual_to_physical(next)).ok_or(MapError::NotAligned)?;
    } else if !l1_entry.is_table() {
        return Err(MapError::SuperpageConflict);
    }

    let l2_table = table_from_physical(l1_entry.output_address().unwrap());
    // SAFETY: L1 was validated as a table descriptor.
    let l2_entry = unsafe { &mut (*l2_table).entries[l2] };
    if !l2_entry.is_valid() {
        let next = allocate_table().ok_or(MapError::OutOfMemory)?;
        *l2_entry = PageTableEntry::table(virtual_to_physical(next)).ok_or(MapError::NotAligned)?;
    } else if !l2_entry.is_table() {
        return Err(MapError::SuperpageConflict);
    }

    let l3_table = table_from_physical(l2_entry.output_address().unwrap());
    // SAFETY: L2 was validated as a table descriptor.
    let slot = unsafe { &mut (*l3_table).entries[l3] };
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
    // SAFETY: The high kernel table is the active kernel owned table. Stack
    // teardown runs before SMP page table sharing exists.
    unsafe { unmap_page(&mut *HIGH_TABLE.get(), virtual_address) }
}

/// Removes one 4 KiB leaf mapping from an existing page table tree.
///
/// # Safety
///
/// `root` and every table descriptor used by this mapping must belong to a
/// valid page table tree owned by the caller. The caller must have exclusive
/// mutation rights to the tree and must not free the physical page until all
/// CPUs that could use the old translation have observed the TLB invalidation.
pub unsafe fn unmap_page(
    root: &mut PageTable,
    virtual_address: VirtualAddress,
) -> Result<PhysicalAddress, UnmapError> {
    if !is_canonical(virtual_address) {
        return Err(UnmapError::NotCanonical);
    }

    let l1 = (virtual_address.get() >> 30) & 0x1ff;
    let l2 = (virtual_address.get() >> 21) & 0x1ff;
    let l3 = (virtual_address.get() >> 12) & 0x1ff;
    let l1_entry = root.entries[l1];
    if !l1_entry.is_table() {
        return Err(if l1_entry.is_valid() {
            UnmapError::SuperpageConflict
        } else {
            UnmapError::NotMapped
        });
    }
    let l2_table = table_from_physical(l1_entry.output_address().unwrap());
    // SAFETY: The L1 table entry was validated as a table descriptor.
    let l2_entry = unsafe { (*l2_table).entries[l2] };
    if !l2_entry.is_table() {
        return Err(if l2_entry.is_valid() {
            UnmapError::SuperpageConflict
        } else {
            UnmapError::NotMapped
        });
    }
    let l3_table = table_from_physical(l2_entry.output_address().unwrap());
    // SAFETY: The L2 table entry was validated as a table descriptor.
    let slot = unsafe { &mut (*l3_table).entries[l3] };
    if !slot.is_valid() {
        return Err(UnmapError::NotMapped);
    }
    let physical = slot.output_address().ok_or(UnmapError::NotMapped)?;
    *slot = PageTableEntry::INVALID;
    // Removing a valid descriptor requires TLB maintenance before reuse.
    TranslationLookasideBuffer::flush_address(virtual_address);
    Ok(physical)
}

pub struct TranslationLookasideBuffer;

impl TranslationLookasideBuffer {
    pub fn flush_all() {
        cpu::data_sync_barrier_inner_shareable();
        // SAFETY: ARM requires DSB before TLBI and DSB+ISB after TLBI. This makes
        // page table updates visible to later instruction and data accesses.
        unsafe { asm!("tlbi alle1is", options(nostack, preserves_flags)) };
        cpu::data_sync_barrier_inner_shareable();
        cpu::instruction_barrier();
    }

    pub fn flush_address(address: VirtualAddress) {
        let operand = (address.get() >> PAGE_SHIFT) & 0x000f_ffff_ffff;
        cpu::data_sync_barrier_inner_shareable();
        // SAFETY: ARM requires the same barrier sequence for address-scoped TLB
        // invalidation. VALE1IS targets the final-level EL1 entry for this page.
        unsafe {
            asm!("tlbi vale1is, {operand}", operand = in(reg) operand, options(nostack, preserves_flags))
        };
        cpu::data_sync_barrier_inner_shareable();
        cpu::instruction_barrier();
    }

    pub fn flush_local() {
        cpu::data_sync_barrier_inner_shareable();
        // SAFETY: VMALLE1 invalidates local EL1 translations. Boot has not
        // started secondary CPUs yet.
        unsafe { asm!("tlbi vmalle1", options(nostack, preserves_flags)) };
        cpu::data_sync_barrier_inner_shareable();
        cpu::instruction_barrier();
    }
}

fn is_canonical(address: VirtualAddress) -> bool {
    address.get() < (1usize << 39) || address.get() >= KERNEL_VIRTUAL_BASE
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

fn kernel_block(address: PhysicalAddress, permissions: MappingPermissions) -> PageTableEntry {
    PageTableEntry::from_mapping(
        MappingIntent::new(
            address,
            MappingSize::Block1G,
            MemoryKind::Normal,
            permissions,
        )
        .expect("boot block is aligned"),
    )
}

fn device_block(address: PhysicalAddress) -> PageTableEntry {
    PageTableEntry::from_mapping(
        MappingIntent::new(
            address,
            MappingSize::Block1G,
            MemoryKind::Device,
            MappingPermissions::KERNEL_READ_WRITE,
        )
        .expect("device block is aligned"),
    )
}

fn apply_permissions(value: &mut u64, permissions: MappingPermissions) {
    if !permissions.writable {
        *value |= PageTableEntry::READ_ONLY;
    }
    if permissions.user_accessible {
        *value |= PageTableEntry::USER_ACCESSIBLE | PageTableEntry::NON_GLOBAL;
    } else {
        *value |= PageTableEntry::USER_EXECUTE_NEVER;
    }
    if !permissions.executable {
        *value |= PageTableEntry::PRIVILEGED_EXECUTE_NEVER | PageTableEntry::USER_EXECUTE_NEVER;
    }
}

fn aligned_output_address(address: PhysicalAddress) -> Option<u64> {
    address
        .is_page_aligned()
        .then_some((address.get() as u64) & 0x0000_ffff_ffff_f000)
}

fn validate_boot_range(start_gb: usize, end_gb: usize) {
    if start_gb > end_gb || end_gb > MAX_BOOT_BLOCKS {
        panic!("mmu: boot physical range exceeds ARM64 boot page table");
    }
}

// TCR_EL1: 39 bit VA, 4 KiB granule, 40-bit PA.
fn default_tcr() -> u64 {
    let mut tcr = 0u64;
    tcr |= 25; // T0SZ
    tcr |= 0b01 << 8; // IRGN0
    tcr |= 0b01 << 10; // ORGN0
    tcr |= 0b10 << 12; // SH0
    tcr |= 25 << 16; // T1SZ
    tcr |= 0b01 << 24; // IRGN1
    tcr |= 0b01 << 26; // ORGN1
    tcr |= 0b10 << 28; // SH1
    tcr |= 0b10 << 30; // TG1
    tcr |= 0b010 << 32; // IPS
    tcr
}

fn write_mair(value: u64) {
    // SAFETY: MAIR_EL1 defines memory attributes referenced by descriptors.
    unsafe {
        asm!("msr mair_el1, {value}", value = in(reg) value, options(nostack, preserves_flags))
    };
    cpu::instruction_barrier();
}

fn write_tcr(value: u64) {
    // SAFETY: TCR_EL1 is programmed before enabling translation.
    unsafe {
        asm!("msr tcr_el1, {value}", value = in(reg) value, options(nostack, preserves_flags))
    };
    cpu::instruction_barrier();
}

fn write_ttbr0(address: PhysicalAddress) {
    // SAFETY: `address` points at the identity-map root table.
    unsafe {
        asm!("msr ttbr0_el1, {address}", address = in(reg) address.get(), options(nostack, preserves_flags))
    };
}

fn write_ttbr1(address: PhysicalAddress) {
    // SAFETY: `address` points at the kernel higher-half root table.
    unsafe {
        asm!("msr ttbr1_el1, {address}", address = in(reg) address.get(), options(nostack, preserves_flags))
    };
    cpu::instruction_barrier();
}

fn enable_mmu() {
    let mut control: u64;
    // SAFETY: SCTLR_EL1 is local CPU state. Setting M enables translation after
    // MAIR/TCR/TTBR are valid and TLBs have been invalidated.
    unsafe {
        asm!("mrs {control}, sctlr_el1", control = out(reg) control, options(nostack, preserves_flags));
        control |= 1;
        asm!("msr sctlr_el1, {control}", control = in(reg) control, options(nostack, preserves_flags));
    }
    cpu::instruction_barrier();
}

const _: () = assert!(core::mem::size_of::<PageTableEntry>() == 8);
const _: () = assert!(core::mem::size_of::<PageTable>() == PAGE_SIZE);
