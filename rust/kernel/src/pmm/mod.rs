//! Physical page allocator.
//!
//! Memory is split into arenas discovered from the DTB. Each arena keeps one
//! metadata entry per physical page. Metadata lives at the end of the arena so
//! low physical addresses remain available for later DMA-sensitive users.

use core::{mem::ManuallyDrop, ptr};

use crate::{
    hwinfo::{HardwareInfo, MemoryRegion},
    limits::{MAX_MEMORY_ARENAS, MAX_RESERVED_REGIONS},
    mmu::{PAGE_SIZE, PhysicalAddress, VirtualAddress},
    sync::SpinLock,
};

const INVALID_ARENA_INDEX: u8 = u8::MAX;
const INVALID_PAGE_INDEX: u32 = u32::MAX;
const KERNEL_RESERVE_PAD: usize = 2 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InitError {
    NoMemoryRegions,
    MetadataTooLarge,
    TooManyReservedRanges,
    AddressNotMapped,
    ArithmeticOverflow,
    PageIndexTooLarge,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FreeContiguousError {
    NotContiguousHead,
    AddressNotInArena,
    NotAllocated,
    InvalidPageState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PageState {
    Free,
    Allocated,
    Reserved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Page {
    previous_free: PageHandle,
    next_free: PageHandle,
    state: PageState,
    arena_index: u8,
    contiguous_head: bool,
}

impl Page {
    const fn new(arena_index: u8, state: PageState) -> Self {
        Self {
            previous_free: PageHandle::NONE,
            next_free: PageHandle::NONE,
            state,
            arena_index,
            contiguous_head: false,
        }
    }

    #[cfg(test)]
    const fn is_contiguous_head(self) -> bool {
        self.contiguous_head
    }
}

impl Default for Page {
    fn default() -> Self {
        Self::new(0, PageState::Free)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PageHandle {
    arena_index: u8,
    page_index: u32,
}

impl PageHandle {
    pub const NONE: Self = Self {
        arena_index: INVALID_ARENA_INDEX,
        page_index: INVALID_PAGE_INDEX,
    };

    const fn new(arena_index: u8, page_index: u32) -> Self {
        Self {
            arena_index,
            page_index,
        }
    }

    const fn is_some(self) -> bool {
        self.page_index != INVALID_PAGE_INDEX
    }
}

#[derive(Clone, Copy)]
struct Arena {
    base: PhysicalAddress,
    page_count: usize,
    usable_pages: usize,
    pages: PageStorage,
}

impl Arena {
    const EMPTY: Self = Self {
        base: PhysicalAddress::ZERO,
        page_count: 0,
        usable_pages: 0,
        pages: PageStorage::empty(),
    };

    fn physical_to_page(self, physical: PhysicalAddress) -> Option<PageHandle> {
        if !physical.is_page_aligned() || physical < self.base {
            return None;
        }
        let offset = physical.get().checked_sub(self.base.get())?;
        let page_index = offset / PAGE_SIZE;
        if page_index >= self.page_count {
            return None;
        }
        Some(PageHandle::new(
            self.pages.arena_index,
            u32::try_from(page_index).ok()?,
        ))
    }

    fn page_to_physical(self, page: PageHandle) -> Option<PhysicalAddress> {
        if page.arena_index != self.pages.arena_index {
            return None;
        }
        let index = page.page_index as usize;
        if index >= self.page_count {
            return None;
        }
        self.base.checked_add(index.checked_mul(PAGE_SIZE)?)
    }

    fn contains_page(self, page: PageHandle) -> bool {
        page.arena_index == self.pages.arena_index && (page.page_index as usize) < self.page_count
    }

    /// # Safety
    ///
    /// Caller must hold the PMM lock and must not create another live metadata
    /// reference for the same page while the returned reference is live.
    unsafe fn page_mut(self, page: PageHandle) -> Option<&'static mut Page> {
        if !self.contains_page(page) {
            return None;
        }
        // SAFETY: The PMM lock gives exclusive metadata access. `contains_page`
        // proved that this handle indexes this arena's metadata slice.
        Some(unsafe { &mut *self.pages.ptr.add(page.page_index as usize) })
    }

    /// # Safety
    ///
    /// Caller must ensure there is no concurrent mutable metadata access for
    /// this page while the returned reference is live.
    unsafe fn page_ref(self, page: PageHandle) -> Option<&'static Page> {
        if !self.contains_page(page) {
            return None;
        }
        // SAFETY: `contains_page` proved that this handle indexes this arena's
        // metadata slice.
        Some(unsafe { &*self.pages.ptr.add(page.page_index as usize) })
    }
}

#[derive(Clone, Copy)]
struct PageStorage {
    ptr: *mut Page,
    len: usize,
    arena_index: u8,
}

impl PageStorage {
    const fn empty() -> Self {
        Self {
            ptr: ptr::null_mut(),
            len: 0,
            arena_index: INVALID_ARENA_INDEX,
        }
    }

    /// # Safety
    ///
    /// Caller must own the whole metadata range and must ensure it is mapped,
    /// initialized only once, and not aliased by any other slice.
    unsafe fn as_mut_slice(self) -> &'static mut [Page] {
        // SAFETY: Arena initialization owns this metadata range inside the
        // physmap. `len` is the number of `Page` entries reserved for it.
        unsafe { core::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

#[derive(Clone, Copy)]
struct ReservedRange {
    start: PhysicalAddress,
    end: PhysicalAddress,
}

impl ReservedRange {
    const EMPTY: Self = Self {
        start: PhysicalAddress::ZERO,
        end: PhysicalAddress::ZERO,
    };

    fn new(start: PhysicalAddress, end: PhysicalAddress) -> Option<Self> {
        (end > start).then_some(Self { start, end })
    }

    fn contains(self, physical: PhysicalAddress) -> bool {
        physical >= self.start && physical < self.end
    }
}

type PhysicalToVirtual = fn(PhysicalAddress) -> VirtualAddress;

struct PhysicalMemoryManager {
    arenas: [Arena; MAX_MEMORY_ARENAS],
    arena_count: usize,
    reserved_ranges: [ReservedRange; MAX_RESERVED_REGIONS],
    reserved_count: usize,
    free_head: PageHandle,
    free_tail: PageHandle,
    total_pages: usize,
    free_pages: usize,
    initialized: bool,
}

impl PhysicalMemoryManager {
    const fn empty() -> Self {
        Self {
            arenas: [Arena::EMPTY; MAX_MEMORY_ARENAS],
            arena_count: 0,
            reserved_ranges: [ReservedRange::EMPTY; MAX_RESERVED_REGIONS],
            reserved_count: 0,
            free_head: PageHandle::NONE,
            free_tail: PageHandle::NONE,
            total_pages: 0,
            free_pages: 0,
            initialized: false,
        }
    }

    fn reset(&mut self) {
        *self = Self::empty();
    }

    fn init(
        &mut self,
        info: &HardwareInfo,
        kernel_start: PhysicalAddress,
        kernel_end: PhysicalAddress,
        physical_to_virtual: PhysicalToVirtual,
    ) -> Result<(), InitError> {
        self.reset();
        self.reserve_kernel(kernel_start, kernel_end)?;
        self.reserve_device_tree(info)?;
        self.reserve_firmware_regions(info)?;

        for region in info.memory_regions() {
            if self.arena_count >= self.arenas.len() {
                break;
            }
            if let Some(arena) =
                self.init_arena(*region, self.arena_count as u8, physical_to_virtual)?
            {
                self.arenas[self.arena_count] = arena;
                self.arena_count += 1;
            }
        }

        if self.arena_count == 0 {
            return Err(InitError::NoMemoryRegions);
        }

        self.mark_reserved_ranges();
        self.build_free_list();
        self.initialized = true;
        Ok(())
    }

    fn reserve_kernel(
        &mut self,
        kernel_start: PhysicalAddress,
        kernel_end: PhysicalAddress,
    ) -> Result<(), InitError> {
        let padded_end = kernel_start
            .checked_add(KERNEL_RESERVE_PAD)
            .ok_or(InitError::ArithmeticOverflow)?;
        let safe_end = core::cmp::max(kernel_end, padded_end);
        self.record_reserved(kernel_start, safe_end)
    }

    fn reserve_device_tree(&mut self, info: &HardwareInfo) -> Result<(), InitError> {
        if info.dtb_phys.get() == 0 || info.dtb_size == 0 {
            return Ok(());
        }
        let start = PhysicalAddress::new(info.dtb_phys.get());
        let end = start
            .checked_add(info.dtb_size)
            .and_then(|address| address.align_up())
            .map(|aligned| aligned.get())
            .ok_or(InitError::ArithmeticOverflow)?;
        self.record_reserved(start, end)
    }

    fn reserve_firmware_regions(&mut self, info: &HardwareInfo) -> Result<(), InitError> {
        for region in info.reserved_regions() {
            if region.size == 0 {
                continue;
            }
            let end = region.end().ok_or(InitError::ArithmeticOverflow)?;
            self.record_reserved(region.base, end)?;
        }
        Ok(())
    }

    fn init_arena(
        &mut self,
        region: MemoryRegion,
        arena_index: u8,
        physical_to_virtual: PhysicalToVirtual,
    ) -> Result<Option<Arena>, InitError> {
        let Some(aligned_base) = region.base.align_up().map(|aligned| aligned.get()) else {
            return Err(InitError::ArithmeticOverflow);
        };
        let Some(region_end) = region.end() else {
            return Err(InitError::ArithmeticOverflow);
        };
        if aligned_base >= region_end {
            return Ok(None);
        }

        let aligned_size = region_end.get() - aligned_base.get();
        let total_pages = aligned_size / PAGE_SIZE;
        if total_pages == 0 {
            return Ok(None);
        }
        if total_pages > u32::MAX as usize {
            return Err(InitError::PageIndexTooLarge);
        }

        let metadata_bytes = total_pages
            .checked_mul(core::mem::size_of::<Page>())
            .ok_or(InitError::ArithmeticOverflow)?;
        let metadata_pages = metadata_bytes.div_ceil(PAGE_SIZE);
        if metadata_pages >= total_pages {
            return Err(InitError::MetadataTooLarge);
        }

        let usable_pages = total_pages - metadata_pages;
        let usable_bytes = usable_pages
            .checked_mul(PAGE_SIZE)
            .ok_or(InitError::ArithmeticOverflow)?;
        let metadata_physical = aligned_base
            .checked_add(usable_bytes)
            .ok_or(InitError::ArithmeticOverflow)?;
        let metadata_virtual = physical_to_virtual(metadata_physical);
        if metadata_virtual.get() == 0 {
            return Err(InitError::AddressNotMapped);
        }

        let storage = PageStorage {
            ptr: metadata_virtual.get() as *mut Page,
            len: total_pages,
            arena_index,
        };
        // SAFETY: The physmap covers the arena. Metadata pages are reserved
        // before they can enter the free list.
        for (index, page) in unsafe { storage.as_mut_slice() }.iter_mut().enumerate() {
            let state = if index >= usable_pages {
                PageState::Reserved
            } else {
                PageState::Free
            };
            *page = Page::new(arena_index, state);
        }

        let metadata_end = metadata_physical
            .checked_add(metadata_pages * PAGE_SIZE)
            .ok_or(InitError::ArithmeticOverflow)?;
        self.record_reserved(metadata_physical, metadata_end)?;
        self.total_pages = self
            .total_pages
            .checked_add(usable_pages)
            .ok_or(InitError::ArithmeticOverflow)?;

        Ok(Some(Arena {
            base: aligned_base,
            page_count: total_pages,
            usable_pages,
            pages: storage,
        }))
    }

    fn record_reserved(
        &mut self,
        start: PhysicalAddress,
        end: PhysicalAddress,
    ) -> Result<(), InitError> {
        let Some(range) = ReservedRange::new(start, end) else {
            return Ok(());
        };
        if self.reserved_count >= self.reserved_ranges.len() {
            return Err(InitError::TooManyReservedRanges);
        }
        self.reserved_ranges[self.reserved_count] = range;
        self.reserved_count += 1;
        Ok(())
    }

    fn mark_reserved_ranges(&mut self) {
        for range_index in 0..self.reserved_count {
            let range = self.reserved_ranges[range_index];
            for arena_index in 0..self.arena_count {
                let arena = self.arenas[arena_index];
                let arena_start = arena.base;
                let Some(arena_end) = arena.base.checked_add(arena.usable_pages * PAGE_SIZE) else {
                    continue;
                };
                if range.end <= arena_start || range.start >= arena_end {
                    continue;
                }
                let start = core::cmp::max(range.start, arena_start);
                let end = core::cmp::min(range.end, arena_end);
                let start_index = (start.get() - arena_start.get()) / PAGE_SIZE;
                let end_index = (end.get() - arena_start.get()).div_ceil(PAGE_SIZE);
                for index in start_index..core::cmp::min(end_index, arena.usable_pages) {
                    let handle = PageHandle::new(arena.pages.arena_index, index as u32);
                    // SAFETY: The computed index is within `usable_pages`.
                    if let Some(page) = unsafe { arena.page_mut(handle) } {
                        page.state = PageState::Reserved;
                    }
                }
            }
        }
    }

    fn build_free_list(&mut self) {
        self.free_head = PageHandle::NONE;
        self.free_tail = PageHandle::NONE;
        self.free_pages = 0;

        for arena_index in 0..self.arena_count {
            let arena = self.arenas[arena_index];
            for index in 0..arena.usable_pages {
                let handle = PageHandle::new(arena.pages.arena_index, index as u32);
                // SAFETY: The loop index is within `usable_pages`.
                let Some(page) = (unsafe { arena.page_mut(handle) }) else {
                    continue;
                };
                if page.state == PageState::Reserved {
                    continue;
                }
                if self.is_reserved(
                    arena
                        .page_to_physical(handle)
                        .unwrap_or(PhysicalAddress::ZERO),
                ) {
                    page.state = PageState::Reserved;
                    continue;
                }
                page.state = PageState::Free;
                self.push_free(handle);
                self.free_pages += 1;
            }
        }
    }

    fn is_reserved(&self, physical: PhysicalAddress) -> bool {
        self.reserved_ranges[..self.reserved_count]
            .iter()
            .any(|range| range.contains(physical))
    }

    fn alloc_page(&mut self) -> Option<PageHandle> {
        let page = self.pop_free()?;
        let arena = self.arena_for(page)?;
        // SAFETY: Free-list handles are inserted only after arena bounds checks.
        let metadata = unsafe { arena.page_mut(page) }?;
        metadata.state = PageState::Allocated;
        self.free_pages -= 1;
        Some(page)
    }

    fn free_page(&mut self, page: PageHandle) {
        let arena = self
            .arena_for(page)
            .unwrap_or_else(|| panic!("pmm: address not in any managed arena"));
        // SAFETY: `arena_for` validated the handle against its arena.
        let metadata = unsafe { arena.page_mut(page) }.unwrap();
        match metadata.state {
            PageState::Free => panic!("pmm: double-free detected"),
            PageState::Reserved => panic!("pmm: cannot free reserved page"),
            PageState::Allocated => {}
        }
        metadata.state = PageState::Free;
        metadata.contiguous_head = false;
        self.push_free(page);
        self.free_pages += 1;
    }

    fn alloc_contiguous(&mut self, count: usize, alignment_log2: u8) -> Option<PageRun> {
        if count == 0 || alignment_log2 >= usize::BITS as u8 {
            return None;
        }
        let alignment = 1usize << alignment_log2;
        let alignment = core::cmp::max(alignment, PAGE_SIZE);

        for arena_index in 0..self.arena_count {
            let arena = self.arenas[arena_index];
            if arena.usable_pages < count {
                continue;
            }
            let mut run_start = None;
            let mut run_length = 0usize;
            for index in 0..arena.usable_pages {
                let handle = PageHandle::new(arena.pages.arena_index, index as u32);
                // SAFETY: The loop index is within `usable_pages`.
                let page = unsafe { arena.page_ref(handle) }?;
                if page.state != PageState::Free {
                    run_start = None;
                    run_length = 0;
                    continue;
                }
                if run_start.is_none() {
                    let physical = arena.page_to_physical(handle)?;
                    if physical.get() & (alignment - 1) != 0 {
                        continue;
                    }
                    run_start = Some(index);
                    run_length = 1;
                } else {
                    run_length += 1;
                }
                if run_length >= count {
                    let start = run_start?;
                    for page_index in start..start + count {
                        let handle = PageHandle::new(arena.pages.arena_index, page_index as u32);
                        self.remove_free(handle);
                        // SAFETY: The run was checked as free and in-bounds.
                        let metadata = unsafe { arena.page_mut(handle) }?;
                        metadata.state = PageState::Allocated;
                    }
                    let head = PageHandle::new(arena.pages.arena_index, start as u32);
                    // SAFETY: `head` is the first page in the allocated run.
                    unsafe { arena.page_mut(head) }?.contiguous_head = true;
                    self.free_pages -= count;
                    return Some(PageRun { head, count });
                }
            }
        }
        None
    }

    fn free_contiguous(
        &mut self,
        head: PageHandle,
        count: usize,
    ) -> Result<(), FreeContiguousError> {
        if count == 0 {
            return Ok(());
        }
        let arena = self
            .arena_for(head)
            .ok_or(FreeContiguousError::AddressNotInArena)?;
        let head_page =
            unsafe { arena.page_ref(head) }.ok_or(FreeContiguousError::AddressNotInArena)?;
        if !head_page.contiguous_head {
            return Err(FreeContiguousError::NotContiguousHead);
        }
        let start = head.page_index as usize;
        let end = start
            .checked_add(count)
            .ok_or(FreeContiguousError::AddressNotInArena)?;
        if end > arena.usable_pages {
            return Err(FreeContiguousError::AddressNotInArena);
        }
        for index in start..end {
            let handle = PageHandle::new(head.arena_index, index as u32);
            let page =
                unsafe { arena.page_ref(handle) }.ok_or(FreeContiguousError::AddressNotInArena)?;
            if page.state != PageState::Allocated {
                return Err(FreeContiguousError::NotAllocated);
            }
            if index != start && page.contiguous_head {
                return Err(FreeContiguousError::InvalidPageState);
            }
        }
        // SAFETY: The head was checked above and remains in the same arena.
        unsafe { arena.page_mut(head) }.unwrap().contiguous_head = false;
        for index in start..end {
            self.free_page(PageHandle::new(head.arena_index, index as u32));
        }
        Ok(())
    }

    fn arena_for(&self, page: PageHandle) -> Option<Arena> {
        let index = page.arena_index as usize;
        let arena = *self.arenas.get(index)?;
        arena.contains_page(page).then_some(arena)
    }

    fn arena_for_physical(&self, physical: PhysicalAddress) -> Option<Arena> {
        self.arenas[..self.arena_count]
            .iter()
            .copied()
            .find(|arena| arena.physical_to_page(physical).is_some())
    }

    fn push_free(&mut self, handle: PageHandle) {
        let arena = self.arena_for(handle).expect("pmm: free page has arena");
        // SAFETY: The caller is mutating the free list while holding the PMM lock.
        let page = unsafe { arena.page_mut(handle) }.expect("pmm: free page has metadata");
        page.previous_free = self.free_tail;
        page.next_free = PageHandle::NONE;
        if self.free_tail.is_some() {
            let tail_arena = self.arena_for(self.free_tail).expect("pmm: tail has arena");
            // SAFETY: The tail handle is currently linked in the free list.
            unsafe { tail_arena.page_mut(self.free_tail) }
                .expect("pmm: tail has metadata")
                .next_free = handle;
        } else {
            self.free_head = handle;
        }
        self.free_tail = handle;
    }

    fn pop_free(&mut self) -> Option<PageHandle> {
        let head = self.free_head;
        if !head.is_some() {
            return None;
        }
        self.remove_free(head);
        Some(head)
    }

    fn remove_free(&mut self, handle: PageHandle) {
        let arena = self.arena_for(handle).expect("pmm: free page has arena");
        // SAFETY: The handle is currently linked in the free list.
        let page = unsafe { arena.page_mut(handle) }.expect("pmm: free page has metadata");
        let previous = page.previous_free;
        let next = page.next_free;
        if previous.is_some() {
            let previous_arena = self.arena_for(previous).expect("pmm: previous has arena");
            // SAFETY: The previous handle is linked to this free node.
            unsafe { previous_arena.page_mut(previous) }
                .expect("pmm: previous has metadata")
                .next_free = next;
        } else {
            self.free_head = next;
        }
        if next.is_some() {
            let next_arena = self.arena_for(next).expect("pmm: next has arena");
            // SAFETY: The next handle is linked to this free node.
            unsafe { next_arena.page_mut(next) }
                .expect("pmm: next has metadata")
                .previous_free = previous;
        } else {
            self.free_tail = previous;
        }
        page.previous_free = PageHandle::NONE;
        page.next_free = PageHandle::NONE;
    }
}

#[must_use = "dropping the page returns it to PMM"]
pub struct AllocatedPage {
    handle: PageHandle,
}

impl AllocatedPage {
    pub fn physical_address(&self) -> Option<PhysicalAddress> {
        page_to_physical_handle(self.handle)
    }

    /// Transfers this page to a subsystem that will return it by physical address.
    ///
    /// Page tables and slab pages outlive the immediate allocation scope. They
    /// are still PMM-owned memory, but the owner is recorded by that subsystem
    /// rather than this RAII value.
    pub fn leak_physical(self) -> Option<PhysicalAddress> {
        let physical = self.physical_address();
        let _this = ManuallyDrop::new(self);
        physical
    }
}

impl Drop for AllocatedPage {
    fn drop(&mut self) {
        free_page_handle(self.handle);
    }
}

#[must_use = "dropping the page run returns it to PMM"]
pub struct PageRun {
    head: PageHandle,
    count: usize,
}

impl PageRun {
    #[cfg(test)]
    pub(crate) const fn empty() -> Self {
        Self {
            head: PageHandle::NONE,
            count: 0,
        }
    }

    #[cfg(test)]
    pub(crate) const fn new_for_test() -> Self {
        Self::empty()
    }

    #[cfg(test)]
    const fn head_for_test(&self) -> PageHandle {
        self.head
    }

    pub const fn count(&self) -> usize {
        self.count
    }

    pub fn physical_address(&self, index: usize) -> Option<PhysicalAddress> {
        if index >= self.count {
            return None;
        }
        let page_index = self
            .head
            .page_index
            .checked_add(u32::try_from(index).ok()?)?;
        page_to_physical_handle(PageHandle::new(self.head.arena_index, page_index))
    }
}

impl Drop for PageRun {
    fn drop(&mut self) {
        if self.count == 0 {
            return;
        }
        let _ = free_contiguous_parts(self.head, self.count);
        self.head = PageHandle::NONE;
        self.count = 0;
    }
}

struct ManagerCell(core::cell::UnsafeCell<PhysicalMemoryManager>);

// SAFETY: Access to the manager is serialized by `PMM_LOCK`.
unsafe impl Sync for ManagerCell {}

static PMM: ManagerCell = ManagerCell(core::cell::UnsafeCell::new(PhysicalMemoryManager::empty()));
static PMM_LOCK: SpinLock = SpinLock::new();

pub fn init(
    info: &HardwareInfo,
    kernel_start: PhysicalAddress,
    kernel_end: PhysicalAddress,
    physical_to_virtual: PhysicalToVirtual,
) -> Result<(), InitError> {
    let _guard = PMM_LOCK.guard();
    manager().init(info, kernel_start, kernel_end, physical_to_virtual)
}

pub fn alloc_page() -> Option<AllocatedPage> {
    let _guard = PMM_LOCK.guard();
    let pmm = manager();
    assert_initialized(pmm);
    pmm.alloc_page().map(|handle| AllocatedPage { handle })
}

fn free_page_handle(page: PageHandle) {
    let _guard = PMM_LOCK.guard();
    let pmm = manager();
    assert_initialized(pmm);
    pmm.free_page(page);
}

pub fn alloc_contiguous(count: usize, alignment_log2: u8) -> Option<PageRun> {
    let _guard = PMM_LOCK.guard();
    let pmm = manager();
    assert_initialized(pmm);
    pmm.alloc_contiguous(count, alignment_log2)
}

fn free_contiguous_parts(head: PageHandle, count: usize) -> Result<(), FreeContiguousError> {
    let _guard = PMM_LOCK.guard();
    let pmm = manager();
    assert_initialized(pmm);
    pmm.free_contiguous(head, count)
}

fn page_to_physical_handle(page: PageHandle) -> Option<PhysicalAddress> {
    let _guard = PMM_LOCK.guard();
    let pmm = manager();
    assert_initialized(pmm);
    pmm.arena_for(page)?.page_to_physical(page)
}

pub(crate) fn free_physical_page(physical: PhysicalAddress) {
    let _guard = PMM_LOCK.guard();
    let pmm = manager();
    assert_initialized(pmm);
    let handle = pmm
        .arena_for_physical(physical)
        .and_then(|arena| arena.physical_to_page(physical))
        .expect("pmm: physical page not managed by PMM");
    pmm.free_page(handle);
}

pub fn total_pages() -> usize {
    let _guard = PMM_LOCK.guard();
    manager().total_pages
}

pub fn free_pages() -> usize {
    let _guard = PMM_LOCK.guard();
    manager().free_pages
}

pub fn arena_count() -> usize {
    let _guard = PMM_LOCK.guard();
    manager().arena_count
}

fn assert_initialized(pmm: &PhysicalMemoryManager) {
    assert!(pmm.initialized, "pmm: not initialized");
}

fn manager() -> &'static mut PhysicalMemoryManager {
    // SAFETY: Callers hold `PMM_LOCK`.
    unsafe { &mut *PMM.0.get() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_handle_round_trips_through_arena() {
        let mut pages = [Page::default(); 4];
        let arena = Arena {
            base: PhysicalAddress::new(0x1000),
            page_count: 4,
            usable_pages: 4,
            pages: PageStorage {
                ptr: pages.as_mut_ptr(),
                len: pages.len(),
                arena_index: 2,
            },
        };

        for index in 0..4 {
            let physical = PhysicalAddress::new(0x1000 + index * PAGE_SIZE);
            let page = arena.physical_to_page(physical).unwrap();
            assert_eq!(page, PageHandle::new(2, index as u32));
            assert_eq!(arena.page_to_physical(page), Some(physical));
        }
        assert_eq!(arena.physical_to_page(PhysicalAddress::new(0x0)), None);
        assert_eq!(arena.physical_to_page(PhysicalAddress::new(0x5000)), None);
        assert_eq!(arena.physical_to_page(PhysicalAddress::new(0x1001)), None);
    }

    #[test]
    fn free_list_reuses_single_page() {
        let mut pages = [Page::default(); 2];
        let storage = PageStorage {
            ptr: pages.as_mut_ptr(),
            len: pages.len(),
            arena_index: 0,
        };
        let mut pmm = PhysicalMemoryManager::empty();
        pmm.arenas[0] = Arena {
            base: PhysicalAddress::new(0x1000),
            page_count: 2,
            usable_pages: 2,
            pages: storage,
        };
        pmm.arena_count = 1;
        pmm.build_free_list();
        pmm.initialized = true;

        let first = pmm.alloc_page().unwrap();
        let second = pmm.alloc_page().unwrap();
        assert_ne!(first, second);
        assert_eq!(pmm.alloc_page(), None);
        pmm.free_page(first);
        assert_eq!(pmm.alloc_page(), Some(first));
    }

    #[test]
    fn contiguous_allocation_validates_head_and_length() {
        let mut pages = [Page::default(); 8];
        let storage = PageStorage {
            ptr: pages.as_mut_ptr(),
            len: pages.len(),
            arena_index: 0,
        };
        let mut pmm = PhysicalMemoryManager::empty();
        pmm.arenas[0] = Arena {
            base: PhysicalAddress::new(0x4000),
            page_count: 8,
            usable_pages: 8,
            pages: storage,
        };
        pmm.arena_count = 1;
        pmm.build_free_list();
        pmm.initialized = true;

        let run = pmm.alloc_contiguous(3, 12).unwrap();
        assert_eq!(run.count(), 3);
        assert_eq!(run.head_for_test(), PageHandle::new(0, 0));
        // SAFETY: The test owns `pmm` and no mutable metadata reference is live.
        assert!(
            unsafe { pmm.arenas[0].page_ref(run.head_for_test()) }
                .unwrap()
                .is_contiguous_head()
        );
        let head = run.head_for_test();
        let count = run.count();
        core::mem::forget(run);
        pmm.free_contiguous(head, count).unwrap();
        assert_eq!(pmm.free_pages, 8);
    }
}
