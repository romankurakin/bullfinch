//! Kernel object allocator.
//!
//! Fixed size pools allocate objects from self contained slab pages. Each slab
//! stores its metadata in slot 0 and an encoded back pointer at the page start,
//! so freeing an object does not need external metadata.

use core::{cell::UnsafeCell, marker::PhantomData, mem::MaybeUninit, ptr::NonNull};

use crate::{
    mmu::{PAGE_SIZE, PhysicalAddress, VirtualAddress},
    pmm,
    sync::SpinLock,
};

const CACHE_LINE_SIZE: usize = 64;
const BACK_POINTER_SIZE: usize = core::mem::size_of::<usize>();
const MIN_SLABS: usize = 1;
const MAX_CLASS: usize = 1024;
const MAX_BITMAP_WORDS: usize = 1;
const POISON_FREE: u8 = 0xdd;

type PageAllocFn = fn() -> Option<NonNull<u8>>;
type PageFreeFn = fn(NonNull<u8>);
type PhysicalToVirtual = fn(PhysicalAddress) -> VirtualAddress;
type VirtualToPhysical = fn(VirtualAddress) -> PhysicalAddress;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AllocError {
    OutOfMemory,
    BadAlignment,
    TooLarge,
    NotInitialized,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FreeError {
    MisalignedPointer,
    MetadataSlot,
    OutOfBounds,
    DoubleFree,
    InvalidSlab,
    NotInitialized,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PoolInitError {
    Alignment,
    Header,
    Object,
}

#[repr(C)]
struct SlabHeader {
    page_addr: usize,
    cookie: usize,
    bitmap: [u64; MAX_BITMAP_WORDS],
    free_count: usize,
    next: *mut SlabHeader,
    prev: *mut SlabHeader,
    in_partial_list: bool,
}

struct Pool<T> {
    alloc_page: PageAllocFn,
    free_page: PageFreeFn,
    cookie: usize,
    current: *mut SlabHeader,
    partial_head: *mut SlabHeader,
    total_allocated: usize,
    slab_count: usize,
    _object: PhantomData<T>,
}

impl<T> Pool<T> {
    const fn empty() -> Self {
        Self {
            alloc_page: no_page_alloc,
            free_page: no_page_free,
            cookie: 0,
            current: core::ptr::null_mut(),
            partial_head: core::ptr::null_mut(),
            total_allocated: 0,
            slab_count: 0,
            _object: PhantomData,
        }
    }

    fn try_new(
        alloc_page: PageAllocFn,
        free_page: PageFreeFn,
        seed: usize,
    ) -> Result<Self, PoolInitError> {
        let mut pool = Self::empty();
        if pool.object_align() > PAGE_SIZE {
            return Err(PoolInitError::Alignment);
        }
        pool.alloc_page = alloc_page;
        pool.free_page = free_page;
        pool.cookie = mix64(seed);
        if core::mem::size_of::<SlabHeader>() > pool.object_size() {
            return Err(PoolInitError::Header);
        }
        if pool.objects_per_slab() <= 1 {
            return Err(PoolInitError::Object);
        }
        Ok(pool)
    }

    fn new(alloc_page: PageAllocFn, free_page: PageFreeFn, seed: usize) -> Self {
        Self::try_new(alloc_page, free_page, seed).expect("slab: unsupported object layout")
    }

    fn alloc(&mut self) -> Option<NonNull<MaybeUninit<T>>> {
        if let Some(slab) = self.current_slab_with_space() {
            return self.alloc_from_slab(slab);
        }

        let slab = self.alloc_new_slab()?;
        self.current = slab.as_ptr();
        self.alloc_from_slab(slab)
    }

    /// # Safety
    ///
    /// `object` must have been returned by this pool and must not have already
    /// been freed. Passing an arbitrary pointer can make the allocator read an
    /// invalid slab back pointer.
    unsafe fn free(&mut self, object: NonNull<MaybeUninit<T>>) -> Result<(), FreeError> {
        let object_addr = object.as_ptr() as usize;
        let page_base = object_addr & !(PAGE_SIZE - 1);
        let back_pointer = page_base as *const usize;
        // SAFETY: `page_base` is derived from the object pointer. Validation
        // below rejects pages whose encoded back pointer does not match this
        // pool before any slab metadata is trusted.
        let encoded = unsafe { back_pointer.read() };
        let slab = self
            .decode_back_pointer(page_base, encoded)
            .ok_or(FreeError::InvalidSlab)?;
        let expected_slab_addr = page_base
            .checked_add(self.usable_start())
            .ok_or(FreeError::InvalidSlab)?;
        if slab.as_ptr() as usize != expected_slab_addr {
            return Err(FreeError::InvalidSlab);
        }

        // SAFETY: The encoded back pointer and expected address checks above
        // prove that this pool owns the slab header for `page_base`.
        let slab_ref = unsafe { slab.as_ref() };
        if slab_ref.page_addr != page_base || slab_ref.cookie != self.slab_cookie(page_base) {
            return Err(FreeError::InvalidSlab);
        }

        let storage_base = page_base
            .checked_add(self.usable_start())
            .ok_or(FreeError::OutOfBounds)?;
        if object_addr < storage_base {
            return Err(FreeError::OutOfBounds);
        }
        let offset = object_addr - storage_base;
        if !offset.is_multiple_of(self.object_size()) {
            return Err(FreeError::MisalignedPointer);
        }

        let slot_index = offset / self.object_size();
        if slot_index == 0 {
            return Err(FreeError::MetadataSlot);
        }
        if slot_index >= self.objects_per_slab() {
            return Err(FreeError::OutOfBounds);
        }

        let word_index = slot_index / 64;
        let bit_mask = 1u64 << (slot_index % 64);
        // SAFETY: The slot was bounds-checked against this slab's bitmap.
        let slab_mut = unsafe { slab.as_ptr().as_mut().unwrap() };
        if slab_mut.bitmap[word_index] & bit_mask != 0 {
            return Err(FreeError::DoubleFree);
        }

        // SAFETY: The object belongs to this slab and is currently allocated.
        unsafe {
            core::ptr::write_bytes(
                object.as_ptr().cast::<u8>(),
                POISON_FREE,
                self.object_size(),
            );
        }

        let was_full = slab_mut.free_count == 0;
        slab_mut.bitmap[word_index] |= bit_mask;
        slab_mut.free_count += 1;
        self.total_allocated -= 1;

        let max_free = self.objects_per_slab() - 1;
        if slab_mut.free_count == max_free && self.slab_count > MIN_SLABS {
            self.unlink_slab(slab);
            self.slab_count -= 1;
            // SAFETY: The page is leaving this pool. Poisoning the back pointer
            // makes stale frees fail the cookie check.
            unsafe {
                (slab_mut.page_addr as *mut usize).write(usize::MAX);
            }
            (self.free_page)(NonNull::new(slab_mut.page_addr as *mut u8).unwrap());
            return Ok(());
        }

        if was_full {
            self.link_slab(slab);
            self.current = slab.as_ptr();
        }
        Ok(())
    }

    #[cfg(test)]
    const fn total_allocated(&self) -> usize {
        self.total_allocated
    }

    #[cfg(test)]
    const fn slab_count(&self) -> usize {
        self.slab_count
    }

    #[cfg(test)]
    fn capacity_per_slab(&self) -> usize {
        self.objects_per_slab()
    }

    #[cfg(test)]
    fn aligned_size(&self) -> usize {
        self.object_size()
    }

    fn current_slab_with_space(&mut self) -> Option<NonNull<SlabHeader>> {
        if let Some(current) = NonNull::new(self.current) {
            // SAFETY: `current` is a slab linked into this pool.
            if unsafe { current.as_ref() }.free_count > 0 {
                return Some(current);
            }
            self.current = self.partial_head;
        }

        while let Some(slab) = NonNull::new(self.current) {
            // SAFETY: `current` walks slabs linked into this pool.
            if unsafe { slab.as_ref() }.free_count > 0 {
                return Some(slab);
            }
            // SAFETY: `slab` is a valid slab header owned by this pool.
            self.current = unsafe { slab.as_ref() }.next;
        }
        None
    }

    fn alloc_from_slab(&mut self, slab: NonNull<SlabHeader>) -> Option<NonNull<MaybeUninit<T>>> {
        // SAFETY: The caller selected a slab owned by this pool.
        let slab_ref = unsafe { slab.as_ptr().as_mut().unwrap() };
        if slab_ref.free_count == 0 {
            return None;
        }

        for word_index in 0..MAX_BITMAP_WORDS {
            let word = slab_ref.bitmap[word_index];
            if word == 0 {
                continue;
            }
            let bit_index = word.trailing_zeros() as usize;
            let slot_index = word_index * 64 + bit_index;
            if slot_index >= self.objects_per_slab() {
                break;
            }

            slab_ref.bitmap[word_index] &= !(1u64 << bit_index);
            slab_ref.free_count -= 1;
            self.total_allocated += 1;
            if slab_ref.free_count == 0 {
                self.unlink_slab(slab);
            }

            let object_addr =
                slab_ref.page_addr + self.usable_start() + slot_index * self.object_size();
            return NonNull::new(object_addr as *mut MaybeUninit<T>);
        }
        None
    }

    fn alloc_new_slab(&mut self) -> Option<NonNull<SlabHeader>> {
        let page = (self.alloc_page)()?;
        let page_addr = page.as_ptr() as usize;
        let slab_addr = page_addr.checked_add(self.usable_start())?;
        let slab = NonNull::new(slab_addr as *mut SlabHeader)?;

        let objects_per_slab = self.objects_per_slab();
        let mut bitmap = [u64::MAX; MAX_BITMAP_WORDS];
        let used_bits = objects_per_slab % 64;
        if used_bits != 0 {
            bitmap[MAX_BITMAP_WORDS - 1] = (1u64 << used_bits) - 1;
        }
        bitmap[0] &= !1u64;

        // SAFETY: The page was just allocated for this pool. Slot 0 stores the
        // slab header and is marked allocated in the bitmap.
        unsafe {
            slab.as_ptr().write(SlabHeader {
                page_addr,
                cookie: self.slab_cookie(page_addr),
                bitmap,
                free_count: objects_per_slab - 1,
                next: core::ptr::null_mut(),
                prev: core::ptr::null_mut(),
                in_partial_list: false,
            });
        }
        // SAFETY: The first word in this owned page stores the encoded slab
        // pointer used to validate frees.
        unsafe { (page_addr as *mut usize).write(self.encode_back_pointer(page_addr, slab)) };

        self.link_slab(slab);
        self.slab_count += 1;
        Some(slab)
    }

    fn link_slab(&mut self, slab: NonNull<SlabHeader>) {
        // SAFETY: `slab` is owned by this pool.
        let slab_ref = unsafe { slab.as_ptr().as_mut().unwrap() };
        slab_ref.next = self.partial_head;
        slab_ref.prev = core::ptr::null_mut();
        if let Some(head) = NonNull::new(self.partial_head) {
            // SAFETY: `partial_head` is linked into this pool.
            unsafe {
                head.as_ptr().as_mut().unwrap().prev = slab.as_ptr();
            }
        }
        self.partial_head = slab.as_ptr();
        slab_ref.in_partial_list = true;
    }

    fn unlink_slab(&mut self, slab: NonNull<SlabHeader>) {
        // SAFETY: `slab` is owned by this pool.
        let slab_ref = unsafe { slab.as_ptr().as_mut().unwrap() };
        if !slab_ref.in_partial_list {
            return;
        }
        if let Some(prev) = NonNull::new(slab_ref.prev) {
            // SAFETY: `prev` is linked before `slab`.
            unsafe {
                prev.as_ptr().as_mut().unwrap().next = slab_ref.next;
            }
        } else {
            self.partial_head = slab_ref.next;
        }
        if let Some(next) = NonNull::new(slab_ref.next) {
            // SAFETY: `next` is linked after `slab`.
            unsafe {
                next.as_ptr().as_mut().unwrap().prev = slab_ref.prev;
            }
        }
        slab_ref.prev = core::ptr::null_mut();
        slab_ref.next = core::ptr::null_mut();
        slab_ref.in_partial_list = false;
        if self.current == slab.as_ptr() {
            self.current = self.partial_head;
        }
    }

    fn object_size(&self) -> usize {
        align_up(core::mem::size_of::<T>().max(1), self.object_align())
    }

    fn object_align(&self) -> usize {
        core::mem::align_of::<T>().max(CACHE_LINE_SIZE)
    }

    fn usable_start(&self) -> usize {
        align_up(BACK_POINTER_SIZE, self.object_align())
    }

    fn objects_per_slab(&self) -> usize {
        let usable_start = self.usable_start();
        if usable_start >= PAGE_SIZE {
            return 0;
        }
        let object_size = self.object_size();
        let mut objects = (PAGE_SIZE - usable_start) / object_size;
        while objects > 0 && usable_start + objects * object_size + MAX_BITMAP_WORDS * 8 > PAGE_SIZE
        {
            objects -= 1;
        }
        objects
    }

    fn slab_cookie(&self, page_addr: usize) -> usize {
        mix64(self.cookie ^ page_addr)
    }

    fn encode_back_pointer(&self, page_addr: usize, slab: NonNull<SlabHeader>) -> usize {
        slab.as_ptr() as usize ^ self.slab_cookie(page_addr)
    }

    fn decode_back_pointer(&self, page_addr: usize, encoded: usize) -> Option<NonNull<SlabHeader>> {
        let decoded = encoded ^ self.slab_cookie(page_addr);
        if !decoded.is_multiple_of(core::mem::align_of::<SlabHeader>()) {
            return None;
        }
        NonNull::new(decoded as *mut SlabHeader)
    }
}

#[repr(C, align(64))]
struct Class<const N: usize> {
    bytes: [u8; N],
}

struct Kmalloc {
    pool_64: Pool<Class<64>>,
    pool_128: Pool<Class<128>>,
    pool_256: Pool<Class<256>>,
    pool_512: Pool<Class<512>>,
    pool_1024: Pool<Class<1024>>,
    initialized: bool,
}

impl Kmalloc {
    const fn empty() -> Self {
        Self {
            pool_64: Pool::empty(),
            pool_128: Pool::empty(),
            pool_256: Pool::empty(),
            pool_512: Pool::empty(),
            pool_1024: Pool::empty(),
            initialized: false,
        }
    }

    fn init(
        &mut self,
        physical_to_virtual: PhysicalToVirtual,
        virtual_to_physical: VirtualToPhysical,
    ) {
        assert!(!self.initialized, "kmalloc: already initialized");
        set_mappers(physical_to_virtual, virtual_to_physical);
        self.pool_64 = Pool::new(pmm_alloc_page, pmm_free_page, seed_for(64));
        self.pool_128 = Pool::new(pmm_alloc_page, pmm_free_page, seed_for(128));
        self.pool_256 = Pool::new(pmm_alloc_page, pmm_free_page, seed_for(256));
        self.pool_512 = Pool::new(pmm_alloc_page, pmm_free_page, seed_for(512));
        self.pool_1024 = Pool::new(pmm_alloc_page, pmm_free_page, seed_for(1024));
        self.initialized = true;
    }

    fn alloc(&mut self, size: usize, alignment: Option<usize>) -> Result<NonNull<u8>, AllocError> {
        if !self.initialized {
            return Err(AllocError::NotInitialized);
        }
        if let Some(alignment) = alignment
            && (alignment == 0 || !alignment.is_power_of_two() || alignment > CACHE_LINE_SIZE)
        {
            return Err(AllocError::BadAlignment);
        }
        if size > MAX_CLASS {
            return Err(AllocError::TooLarge);
        }

        let want = size.max(CACHE_LINE_SIZE);
        match size_class(want).ok_or(AllocError::TooLarge)? {
            SizeClass::Class64 => self
                .pool_64
                .alloc()
                .map(NonNull::cast)
                .ok_or(AllocError::OutOfMemory),
            SizeClass::Class128 => self
                .pool_128
                .alloc()
                .map(NonNull::cast)
                .ok_or(AllocError::OutOfMemory),
            SizeClass::Class256 => self
                .pool_256
                .alloc()
                .map(NonNull::cast)
                .ok_or(AllocError::OutOfMemory),
            SizeClass::Class512 => self
                .pool_512
                .alloc()
                .map(NonNull::cast)
                .ok_or(AllocError::OutOfMemory),
            SizeClass::Class1024 => self
                .pool_1024
                .alloc()
                .map(NonNull::cast)
                .ok_or(AllocError::OutOfMemory),
        }
    }

    /// # Safety
    ///
    /// `ptr` must have been returned by this allocator and must not have
    /// already been freed.
    unsafe fn free(&mut self, ptr: NonNull<u8>) -> Result<(), FreeError> {
        if !self.initialized {
            return Err(FreeError::NotInitialized);
        }
        // SAFETY: `free` is unsafe and requires the caller to pass a live
        // pointer from this allocator.
        if unsafe { try_free(&mut self.pool_64, ptr) }? {
            return Ok(());
        }
        // SAFETY: Same caller-owned pointer contract as above. This probes the
        // next size class without taking ownership unless it matches.
        if unsafe { try_free(&mut self.pool_128, ptr) }? {
            return Ok(());
        }
        // SAFETY: Same caller-owned pointer contract as above. This probes the
        // next size class without taking ownership unless it matches.
        if unsafe { try_free(&mut self.pool_256, ptr) }? {
            return Ok(());
        }
        // SAFETY: Same caller-owned pointer contract as above. This probes the
        // next size class without taking ownership unless it matches.
        if unsafe { try_free(&mut self.pool_512, ptr) }? {
            return Ok(());
        }
        // SAFETY: Same caller-owned pointer contract as above. This probes the
        // final size class.
        if unsafe { try_free(&mut self.pool_1024, ptr) }? {
            return Ok(());
        }
        Err(FreeError::InvalidSlab)
    }
}

enum SizeClass {
    Class64,
    Class128,
    Class256,
    Class512,
    Class1024,
}

#[must_use = "dropping the allocation frees it"]
pub struct KernelAllocation {
    ptr: NonNull<u8>,
    size: usize,
}

impl KernelAllocation {
    pub const fn as_non_null(&self) -> NonNull<u8> {
        self.ptr
    }

    pub const fn as_ptr(&self) -> *mut u8 {
        self.ptr.as_ptr()
    }

    pub const fn size(&self) -> usize {
        self.size
    }
}

impl Drop for KernelAllocation {
    fn drop(&mut self) {
        // SAFETY: `KernelAllocation` is constructed only by `alloc`, and this
        // `Drop` implementation is the only owner-side free path.
        let _ = unsafe { free_raw(self.ptr) };
    }
}

struct KmallocCell(UnsafeCell<Kmalloc>);

// SAFETY: All global allocator access is serialized by `KMALLOC_LOCK`.
unsafe impl Sync for KmallocCell {}

static KMALLOC: KmallocCell = KmallocCell(UnsafeCell::new(Kmalloc::empty()));
static KMALLOC_LOCK: SpinLock = SpinLock::new();
static MAPPERS: MapperCell = MapperCell(UnsafeCell::new(Mappers::identity()));

pub fn init(physical_to_virtual: PhysicalToVirtual, virtual_to_physical: VirtualToPhysical) {
    let _guard = KMALLOC_LOCK.guard();
    kmalloc().init(physical_to_virtual, virtual_to_physical);
}

pub fn alloc(size: usize, alignment: Option<usize>) -> Result<KernelAllocation, AllocError> {
    let ptr = alloc_raw(size, alignment)?;
    Ok(KernelAllocation { ptr, size })
}

fn alloc_raw(size: usize, alignment: Option<usize>) -> Result<NonNull<u8>, AllocError> {
    let _guard = KMALLOC_LOCK.guard();
    kmalloc().alloc(size, alignment)
}

/// # Safety
///
/// `ptr` must have been returned by `alloc_raw` and must not have already been
/// freed. Passing a forged pointer can make the allocator read an invalid slab
/// back pointer.
unsafe fn free_raw(ptr: NonNull<u8>) -> Result<(), FreeError> {
    let _guard = KMALLOC_LOCK.guard();
    // SAFETY: The caller proves `ptr` belongs to this allocator and is not
    // already freed. The lock gives exclusive allocator access.
    unsafe { kmalloc().free(ptr) }
}

pub fn boot_probe() -> Result<(), AllocError> {
    let _object = alloc(CACHE_LINE_SIZE, None)?;
    Ok(())
}

/// # Safety
///
/// Caller must uphold the kmalloc `free` contract for `ptr`.
unsafe fn try_free<const N: usize>(
    pool: &mut Pool<Class<N>>,
    ptr: NonNull<u8>,
) -> Result<bool, FreeError> {
    // SAFETY: The caller upholds the kmalloc `free` contract. This helper only
    // probes which pool owns the pointer.
    match unsafe { pool.free(ptr.cast::<MaybeUninit<Class<N>>>()) } {
        Ok(()) => Ok(true),
        Err(FreeError::InvalidSlab) => Ok(false),
        Err(error) => Err(error),
    }
}

fn pmm_alloc_page() -> Option<NonNull<u8>> {
    let page = pmm::alloc_page()?;
    let physical = page.leak_physical()?;
    let virtual_address = mappers().physical_to_virtual(physical);
    NonNull::new(virtual_address.get() as *mut u8)
}

fn pmm_free_page(page: NonNull<u8>) {
    let physical = mappers().virtual_to_physical(VirtualAddress::new(page.as_ptr() as usize));
    pmm::free_physical_page(physical);
}

fn kmalloc() -> &'static mut Kmalloc {
    // SAFETY: Callers hold `KMALLOC_LOCK` or are executing from a pool callback
    // called while the lock is held.
    unsafe { &mut *KMALLOC.0.get() }
}

struct Mappers {
    physical_to_virtual: PhysicalToVirtual,
    virtual_to_physical: VirtualToPhysical,
}

impl Mappers {
    const fn identity() -> Self {
        Self {
            physical_to_virtual: identity_physical_to_virtual,
            virtual_to_physical: identity_virtual_to_physical,
        }
    }

    fn physical_to_virtual(&self, address: PhysicalAddress) -> VirtualAddress {
        (self.physical_to_virtual)(address)
    }

    fn virtual_to_physical(&self, address: VirtualAddress) -> PhysicalAddress {
        (self.virtual_to_physical)(address)
    }
}

struct MapperCell(UnsafeCell<Mappers>);

// SAFETY: Mappers are written once during allocator init before allocations can
// reach PMM-backed slabs. Later reads use immutable function pointers.
unsafe impl Sync for MapperCell {}

fn set_mappers(physical_to_virtual: PhysicalToVirtual, virtual_to_physical: VirtualToPhysical) {
    // SAFETY: Global allocator init holds `KMALLOC_LOCK` and runs before public
    // allocation succeeds.
    unsafe {
        *MAPPERS.0.get() = Mappers {
            physical_to_virtual,
            virtual_to_physical,
        };
    }
}

fn mappers() -> &'static Mappers {
    // SAFETY: After `init`, mapper function pointers are immutable.
    unsafe { &*MAPPERS.0.get() }
}

fn size_class(size: usize) -> Option<SizeClass> {
    if size <= 64 {
        Some(SizeClass::Class64)
    } else if size <= 128 {
        Some(SizeClass::Class128)
    } else if size <= 256 {
        Some(SizeClass::Class256)
    } else if size <= 512 {
        Some(SizeClass::Class512)
    } else if size <= 1024 {
        Some(SizeClass::Class1024)
    } else {
        None
    }
}

fn align_up(value: usize, alignment: usize) -> usize {
    (value + alignment - 1) & !(alignment - 1)
}

fn seed_for(size: usize) -> usize {
    mix64(size ^ pmm_alloc_page as *const () as usize ^ pmm_free_page as *const () as usize)
}

fn mix64(value: usize) -> usize {
    let mut z = value.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

fn no_page_alloc() -> Option<NonNull<u8>> {
    None
}

fn no_page_free(_: NonNull<u8>) {}

fn identity_physical_to_virtual(address: PhysicalAddress) -> VirtualAddress {
    VirtualAddress::new(address.get())
}

fn identity_virtual_to_physical(address: VirtualAddress) -> PhysicalAddress {
    PhysicalAddress::new(address.get())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, thread_local};

    thread_local! {
        static TEST_STATE: RefCell<TestState> = const { RefCell::new(TestState::new()) };
    }

    struct TestState {
        pages: [TestPage; 8],
        next: usize,
        freed: [usize; 8],
        freed_count: usize,
    }

    impl TestState {
        const fn new() -> Self {
            Self {
                pages: [TestPage([0; PAGE_SIZE]); 8],
                next: 0,
                freed: [0; 8],
                freed_count: 0,
            }
        }

        fn reset(&mut self) {
            self.next = 0;
            self.freed_count = 0;
        }
    }

    fn test_alloc_page() -> Option<NonNull<u8>> {
        TEST_STATE.with_borrow_mut(|state| {
            if state.next >= state.pages.len() {
                return None;
            }
            let index = state.next;
            state.next += 1;
            NonNull::new(state.pages[index].0.as_mut_ptr())
        })
    }

    fn test_free_page(page: NonNull<u8>) {
        TEST_STATE.with_borrow_mut(|state| {
            let index = state.freed_count;
            state.freed[index] = page.as_ptr() as usize;
            state.freed_count += 1;
        });
    }

    #[repr(C)]
    struct TestObject {
        value: u64,
        padding: [u8; 56],
    }

    #[repr(align(4096))]
    #[derive(Clone, Copy)]
    struct TestPage([u8; PAGE_SIZE]);

    #[test]
    fn calculates_pool_layout() {
        let pool = Pool::<TestObject>::new(test_alloc_page, test_free_page, 1);
        assert_eq!(pool.aligned_size(), CACHE_LINE_SIZE);
        assert!(pool.capacity_per_slab() > 1);
    }

    #[test]
    fn allocates_and_frees_from_pool() {
        TEST_STATE.with_borrow_mut(TestState::reset);
        let mut pool = Pool::<TestObject>::new(test_alloc_page, test_free_page, 2);

        let first = pool.alloc().unwrap();
        let second = pool.alloc().unwrap();
        assert_ne!(first, second);
        assert_eq!(pool.total_allocated(), 2);

        // SAFETY: `first` came from this pool and is freed once.
        unsafe { pool.free(first) }.unwrap();
        assert_eq!(pool.total_allocated(), 1);
        // SAFETY: `second` came from this pool and is freed once.
        unsafe { pool.free(second) }.unwrap();
        assert_eq!(pool.total_allocated(), 0);
    }

    #[test]
    fn reuses_freed_slot_from_full_slab() {
        TEST_STATE.with_borrow_mut(TestState::reset);
        let mut pool = Pool::<TestObject>::new(test_alloc_page, test_free_page, 3);
        let capacity = pool.capacity_per_slab();
        let mut objects = std::vec::Vec::new();
        for _ in 1..capacity {
            objects.push(pool.alloc().unwrap());
        }
        assert_eq!(pool.slab_count(), 1);

        let freed = objects[0];
        // SAFETY: `freed` came from this pool and has not been freed.
        unsafe { pool.free(freed) }.unwrap();
        let reused = pool.alloc().unwrap();
        assert_eq!(reused, freed);
    }

    #[test]
    fn reclaims_empty_slab_above_minimum() {
        TEST_STATE.with_borrow_mut(TestState::reset);
        let mut pool = Pool::<TestObject>::new(test_alloc_page, test_free_page, 4);
        let capacity = pool.capacity_per_slab();
        let mut first_slab = std::vec::Vec::new();
        for _ in 1..capacity {
            first_slab.push(pool.alloc().unwrap());
        }
        let second_slab_object = pool.alloc().unwrap();
        assert_eq!(pool.slab_count(), 2);

        // SAFETY: `second_slab_object` came from this pool and has not been freed.
        unsafe { pool.free(second_slab_object) }.unwrap();
        assert_eq!(pool.slab_count(), 1);
        TEST_STATE.with_borrow(|state| assert_eq!(state.freed_count, 1));
    }

    #[test]
    fn reports_free_errors() {
        TEST_STATE.with_borrow_mut(TestState::reset);
        let mut pool = Pool::<TestObject>::new(test_alloc_page, test_free_page, 5);
        let object = pool.alloc().unwrap();
        let object_addr = object.as_ptr() as usize;
        let page_base = object_addr & !(PAGE_SIZE - 1);
        let storage_base = page_base + pool.usable_start();

        let misaligned = NonNull::new((object_addr + 1) as *mut MaybeUninit<TestObject>).unwrap();
        // SAFETY: Error path test passes malformed pointers to validate checks.
        let misaligned_result = unsafe { pool.free(misaligned) };
        assert_eq!(misaligned_result, Err(FreeError::MisalignedPointer));

        let metadata = NonNull::new(storage_base as *mut MaybeUninit<TestObject>).unwrap();
        // SAFETY: Error path test passes the metadata slot intentionally.
        assert_eq!(unsafe { pool.free(metadata) }, Err(FreeError::MetadataSlot));

        let out_of_bounds = NonNull::new(
            (storage_base + pool.capacity_per_slab() * pool.aligned_size())
                as *mut MaybeUninit<TestObject>,
        )
        .unwrap();
        // SAFETY: Error path test passes an out of bounds slot intentionally.
        let out_of_bounds_result = unsafe { pool.free(out_of_bounds) };
        assert_eq!(out_of_bounds_result, Err(FreeError::OutOfBounds));

        // SAFETY: `object` came from this pool and has not been freed.
        unsafe { pool.free(object) }.unwrap();
        // SAFETY: Error path test intentionally repeats the free.
        assert_eq!(unsafe { pool.free(object) }, Err(FreeError::DoubleFree));
    }

    #[test]
    fn rejects_corrupted_back_pointer() {
        TEST_STATE.with_borrow_mut(TestState::reset);
        let mut pool = Pool::<TestObject>::new(test_alloc_page, test_free_page, 6);
        let object = pool.alloc().unwrap();
        let page_base = (object.as_ptr() as usize) & !(PAGE_SIZE - 1);
        let back_pointer = page_base as *mut usize;
        // SAFETY: Test owns the fake page and intentionally corrupts metadata.
        let saved = unsafe { back_pointer.read() };
        // SAFETY: Test-only metadata corruption.
        unsafe {
            back_pointer.write(0);
        }
        // SAFETY: Error path test intentionally corrupts the slab back pointer.
        assert_eq!(unsafe { pool.free(object) }, Err(FreeError::InvalidSlab));
        // SAFETY: Restore metadata before freeing the live object.
        unsafe {
            back_pointer.write(saved);
        }
        // SAFETY: Metadata was restored and `object` is still allocated.
        unsafe { pool.free(object) }.unwrap();
    }

    #[test]
    fn kmalloc_class_selection_validates_inputs() {
        assert!(matches!(size_class(64), Some(SizeClass::Class64)));
        assert!(matches!(size_class(65), Some(SizeClass::Class128)));
        assert!(matches!(size_class(1024), Some(SizeClass::Class1024)));
        assert!(size_class(1025).is_none());
    }
}
