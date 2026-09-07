//! Task and scheduler model.
//!
//! The scheduler owns threads and exposes opaque IDs for lookup. Each non-idle
//! thread accumulates virtual runtime: CPU time adjusted by its scheduling
//! weight. The scheduler favors ready threads with the lowest virtual runtime.
//! A larger weight makes this value grow more slowly, giving the thread a
//! larger share of CPU time. The idle thread runs when no other thread is ready.

use core::{mem::ManuallyDrop, num::NonZeroU32};

use crate::{
    clock,
    context::Context,
    fp::ThreadFpState,
    limits::MAX_TASKS,
    mmu::{MapError, PAGE_SIZE, PhysicalAddress, UnmapError, VirtualAddress},
    pmm::{self, PageRun},
    sync::Locked,
    trace::{Ring, TRACE_EVENTS, TraceEvent, TraceKind},
};

pub const KERNEL_STACK_SIZE: usize = PAGE_SIZE * 2;
pub const SCHED_BASE_WEIGHT: u32 = 1024;
pub const SCHED_MIN_WEIGHT: u32 = 1;
pub const SCHED_TIME_SLICE_NS: u64 = 1_000_000_000 / clock::TICK_RATE_HZ;

const MAX_PROCESSES: usize = 8;
const KERNEL_STACK_PAGES: usize = KERNEL_STACK_SIZE / PAGE_SIZE;
const PAGE_ALIGNMENT_LOG2: u8 = 12;
const KERNEL_STACK_GUARD_SIZE: usize = PAGE_SIZE;
const KERNEL_STACK_SLOT_SIZE: usize = KERNEL_STACK_GUARD_SIZE + KERNEL_STACK_SIZE;
const KERNEL_STACK_REGION_SIZE: usize = 1 << 30;
const MAX_KERNEL_STACK_SLOTS: usize = KERNEL_STACK_REGION_SIZE / KERNEL_STACK_SLOT_SIZE;
const STACK_SLOT_WORD_BITS: usize = usize::BITS as usize;
const STACK_SLOT_WORDS: usize = MAX_KERNEL_STACK_SLOTS.div_ceil(STACK_SLOT_WORD_BITS);

// Protects the virtual stack-slot bitmap. A claimed slot stays reserved until
// its KernelStackSlot guard is dropped, even while the bitmap lock is released.
static STACK_SLOTS: Locked<StackSlots> = Locked::new(StackSlots::new());

// Charge elapsed time in nanoseconds, scaled by base_weight / thread_weight.
// A thread with twice the base weight receives half the charge for the same
// elapsed time. Use u128 for the intermediate product, then saturate to u64.
fn scaled_vruntime_delta(elapsed_ticks: u64, weight: NonZeroU32) -> u64 {
    if weight.get() == SCHED_BASE_WEIGHT {
        return SCHED_TIME_SLICE_NS.saturating_mul(elapsed_ticks);
    }

    let elapsed_ns = u128::from(SCHED_TIME_SLICE_NS) * u128::from(elapsed_ticks);
    let scaled = elapsed_ns * u128::from(SCHED_BASE_WEIGHT) / u128::from(weight.get());
    u64::try_from(scaled).unwrap_or(u64::MAX)
}

pub type KernelStackRegionBase = fn() -> VirtualAddress;
pub type MapKernelStackPage = fn(VirtualAddress, PhysicalAddress) -> Result<(), MapError>;
pub type UnmapKernelStackPage = fn(VirtualAddress) -> Result<PhysicalAddress, UnmapError>;
pub type ThreadEntry = extern "C" fn(usize) -> !;
pub type ContextSwitch = unsafe fn(&mut Context, &Context);

/// Architecture operations that jointly transfer FP and integer context at a
/// trap-return boundary.
///
/// One type supplies both operations, so callers cannot select unrelated FP
/// and integer switch implementations. The type parameter selects the calls
/// at compile time.
pub trait TrapContextSwitch {
    /// Transfers the resident FP register file between scheduler threads.
    ///
    /// # Safety
    ///
    /// `old` and `new` must be the outgoing and incoming scheduler FP states.
    /// Trap entry must have disabled kernel FP access.
    unsafe fn switch_fp(old: &mut ThreadFpState, new: &ThreadFpState);

    /// Transfers the integer context and kernel stack.
    ///
    /// # Safety
    ///
    /// `old` and `new` must be the matching scheduler context pair.
    /// The caller must be returning through an architecture trap frame.
    unsafe fn switch_integer(old: &mut Context, new: &Context);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StackError {
    OutOfMemory,
    AddressNotMapped,
    RegionExhausted,
    Map(MapError),
}

/// Owns stack pages and their mappings in the kernel stack region.
///
/// Each slot leaves one unmapped guard page below the usable stack, so a
/// downward overflow into that page faults. Drop removes the stack mappings
/// before returning the physical pages and virtual slot for reuse.
pub struct KernelStack {
    pages: ManuallyDrop<PageRun>,
    slot: ManuallyDrop<Option<KernelStackSlot>>,
    base: VirtualAddress,
    size: usize,
    unmap: Option<UnmapKernelStackPage>,
}

// Owns an unfinished stack. `mapped_pages` counts the successfully mapped
// prefix, so an early return unmaps only that prefix before freeing resources.
// `finish` transfers ownership to KernelStack and disarms this rollback.
struct KernelStackBuild {
    pages: ManuallyDrop<PageRun>,
    slot: ManuallyDrop<KernelStackSlot>,
    base: VirtualAddress,
    mapped_pages: usize,
    unmap: UnmapKernelStackPage,
    armed: bool,
}

struct StackSlots {
    words: [usize; STACK_SLOT_WORDS],
}

impl StackSlots {
    const fn new() -> Self {
        Self {
            words: [0; STACK_SLOT_WORDS],
        }
    }

    fn alloc(&mut self) -> Option<usize> {
        for (word_index, word) in self.words.iter_mut().enumerate() {
            if *word == usize::MAX {
                continue;
            }
            let bit = (!*word).trailing_zeros() as usize;
            let slot = word_index * STACK_SLOT_WORD_BITS + bit;
            if slot >= MAX_KERNEL_STACK_SLOTS {
                return None;
            }
            *word |= 1usize << bit;
            return Some(slot);
        }
        None
    }

    fn free(&mut self, slot: usize) {
        let word = slot / STACK_SLOT_WORD_BITS;
        let bit = slot % STACK_SLOT_WORD_BITS;
        let mask = 1usize << bit;
        assert!(self.words[word] & mask != 0, "task: stack slot double-free");
        self.words[word] &= !mask;
    }
}

struct KernelStackSlot {
    index: usize,
}

impl KernelStackSlot {
    fn alloc() -> Option<Self> {
        STACK_SLOTS.lock().alloc().map(|index| Self { index })
    }

    const fn index(&self) -> usize {
        self.index
    }
}

impl Drop for KernelStackSlot {
    fn drop(&mut self) {
        STACK_SLOTS.lock().free(self.index);
    }
}

impl KernelStackBuild {
    fn new(
        pages: PageRun,
        slot: KernelStackSlot,
        base: VirtualAddress,
        unmap: UnmapKernelStackPage,
    ) -> Self {
        Self {
            pages: ManuallyDrop::new(pages),
            slot: ManuallyDrop::new(slot),
            base,
            mapped_pages: 0,
            unmap,
            armed: true,
        }
    }

    fn finish(mut self) -> KernelStack {
        debug_assert_eq!(self.mapped_pages, KERNEL_STACK_PAGES);
        self.armed = false;
        // SAFETY: Disarming the build guard prevents its `Drop` implementation
        // from touching either value after ownership moves to `KernelStack`.
        let pages = unsafe { ManuallyDrop::take(&mut self.pages) };
        // SAFETY: The guard is disarmed and this slot is moved exactly once.
        let slot = unsafe { ManuallyDrop::take(&mut self.slot) };
        KernelStack {
            pages: ManuallyDrop::new(pages),
            slot: ManuallyDrop::new(Some(slot)),
            base: self.base,
            size: KERNEL_STACK_SIZE,
            unmap: Some(self.unmap),
        }
    }
}

impl Drop for KernelStackBuild {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        unmap_stack_mapping_strict(self.base, self.mapped_pages, self.unmap);
        // SAFETY: Strict unmapping removed every virtual alias. If it panics,
        // these lines are not reached and `ManuallyDrop` deliberately leaks
        // both resources instead of allowing stale mappings to be reused.
        unsafe { ManuallyDrop::drop(&mut self.pages) };
        // SAFETY: The slot is released exactly once after all aliases are gone.
        unsafe { ManuallyDrop::drop(&mut self.slot) };
    }
}

impl KernelStack {
    /// Maps a new stack, leaving the guard page at the bottom of its slot unmapped.
    ///
    /// A mapping error rolls back earlier mappings. Failure to unmap during
    /// rollback or drop panics: reusing pages while old mappings survive would
    /// let a stale stack address access a new owner's memory.
    pub fn create_mapped(
        stack_region_base: KernelStackRegionBase,
        map_page: MapKernelStackPage,
        unmap_page: UnmapKernelStackPage,
    ) -> Result<Self, StackError> {
        let slot = KernelStackSlot::alloc().ok_or(StackError::RegionExhausted)?;
        let base = stack_region_base()
            .checked_add(
                slot.index()
                    .checked_mul(KERNEL_STACK_SLOT_SIZE)
                    .and_then(|offset| offset.checked_add(KERNEL_STACK_GUARD_SIZE))
                    .ok_or(StackError::RegionExhausted)?,
            )
            .ok_or(StackError::RegionExhausted)?;
        let pages = pmm::alloc_contiguous(KERNEL_STACK_PAGES, PAGE_ALIGNMENT_LOG2)
            .ok_or(StackError::OutOfMemory)?;
        let mut build = KernelStackBuild::new(pages, slot, base, unmap_page);

        while build.mapped_pages < KERNEL_STACK_PAGES {
            let index = build.mapped_pages;
            let Some(physical) = build.pages.physical_address(index) else {
                return Err(StackError::AddressNotMapped);
            };
            let virtual_address = base
                .checked_add(index * PAGE_SIZE)
                .ok_or(StackError::RegionExhausted)?;
            if let Err(error) = map_page(virtual_address, physical) {
                return Err(StackError::Map(error));
            }
            build.mapped_pages += 1;
        }

        Ok(build.finish())
    }

    pub fn boot_probe(
        stack_region_base: KernelStackRegionBase,
        map_page: MapKernelStackPage,
        unmap_page: UnmapKernelStackPage,
    ) -> Result<(), StackError> {
        let _stack = Self::create_mapped(stack_region_base, map_page, unmap_page)?;
        Ok(())
    }

    #[cfg(test)]
    fn new_for_test(base: VirtualAddress, size: usize) -> Self {
        Self {
            pages: ManuallyDrop::new(PageRun::new_for_test()),
            slot: ManuallyDrop::new(None),
            base,
            size,
            unmap: None,
        }
    }

    pub const fn base(&self) -> VirtualAddress {
        self.base
    }

    pub fn top(&self) -> VirtualAddress {
        VirtualAddress::new(self.base.get() + self.size)
    }

    pub const fn size(&self) -> usize {
        self.size
    }
}

impl Drop for KernelStack {
    fn drop(&mut self) {
        if let Some(unmap_page) = self.unmap {
            unmap_stack_mapping_strict(self.base, KERNEL_STACK_PAGES, unmap_page);
        }
        // SAFETY: `pages` is dropped exactly once here after the virtual stack
        // aliases are gone. If strict unmapping panics, the run and stack slot
        // stay leaked instead of being reused with stale mappings.
        unsafe { ManuallyDrop::drop(&mut self.pages) };
        // SAFETY: The slot is released exactly once, after stale aliases have
        // been removed and the physical pages have been returned.
        unsafe { ManuallyDrop::drop(&mut self.slot) };
    }
}

fn unmap_stack_mapping_strict(
    base: VirtualAddress,
    mapped_pages: usize,
    unmap_page: UnmapKernelStackPage,
) {
    let mut index = mapped_pages;
    while index > 0 {
        index -= 1;
        let virtual_address = base
            .checked_add(index * PAGE_SIZE)
            .expect("kernel stack mapping address overflow during teardown");
        unmap_page(virtual_address).expect("kernel stack unmap failed during teardown");
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InitError {
    ProcessTableFull,
    ThreadTableFull,
    MissingKernelStack,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScheduleError {
    NotInitialized,
    NoCurrentThread,
    UnknownThread,
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProcessId(u32);

impl ProcessId {
    pub const fn get(self) -> u32 {
        self.0
    }
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ThreadId(u32);

impl ThreadId {
    pub const fn get(self) -> u32 {
        self.0
    }
}

/// Bootstrap-only authority for creating initial kernel threads.
///
/// This authority applies only during bootstrap. Future userspace process
/// and service creation should use capability handles with rights checks.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BootstrapProcess {
    id: ProcessId,
}

impl BootstrapProcess {
    pub fn spawn(
        self,
        weight: NonZeroU32,
        stack: KernelStack,
        entry: ThreadEntry,
        arg: usize,
    ) -> Result<ThreadId, InitError> {
        SCHEDULER
            .lock()
            .create_thread_with_stack(self.id, weight, false, stack, entry, arg)
    }
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WaitToken(usize);

impl WaitToken {
    pub const fn new(raw: usize) -> Option<Self> {
        if raw == 0 { None } else { Some(Self(raw)) }
    }

    pub const fn get(self) -> usize {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessState {
    Active,
    Exiting,
    Zombie,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ThreadState {
    Ready,
    Running,
    Blocked,
    Exited,
}

impl ThreadState {
    pub const fn is_runnable(self) -> bool {
        matches!(self, Self::Ready | Self::Running)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Switch {
    pub previous: ThreadId,
    pub next: ThreadId,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ThreadSnapshot {
    pub id: ThreadId,
    pub process: ProcessId,
    pub state: ThreadState,
    pub weight: NonZeroU32,
    pub virtual_runtime: u64,
    pub blocked_on: Option<WaitToken>,
}

#[derive(Clone, Copy)]
struct Process {
    id: ProcessId,
    first_thread: Option<ThreadId>,
    thread_count: u32,
    state: ProcessState,
}

impl Process {
    const fn new(id: ProcessId) -> Self {
        Self {
            id,
            first_thread: None,
            thread_count: 0,
            state: ProcessState::Active,
        }
    }

    fn add_thread(&mut self, thread: &mut Thread) {
        thread.process_next = self.first_thread;
        self.first_thread = Some(thread.id);
        thread.process = self.id;
        self.thread_count += 1;
    }

    #[cfg(test)]
    fn remove_thread(&mut self, thread_id: ThreadId, threads: &mut [Option<Thread>]) -> bool {
        let mut previous = None;
        let mut current = self.first_thread;
        while let Some(current_id) = current {
            let Some(current_thread) = find_thread_mut(threads, current_id) else {
                break;
            };
            if current_id == thread_id {
                let next = current_thread.process_next;
                current_thread.process_next = None;
                if let Some(previous_id) = previous {
                    if let Some(previous_thread) = find_thread_mut(threads, previous_id) {
                        previous_thread.process_next = next;
                    }
                } else {
                    self.first_thread = next;
                }
                self.thread_count -= 1;
                return self.thread_count == 0;
            }
            previous = current;
            current = current_thread.process_next;
        }
        false
    }
}

struct Thread {
    id: ThreadId,
    process: ProcessId,
    state: ThreadState,
    context: Context,
    fp: ThreadFpState,
    stack: Option<KernelStack>,
    blocked_on: Option<WaitToken>,
    weight: NonZeroU32,
    virtual_runtime: u64,
    process_next: Option<ThreadId>,
    idle: bool,
}

// TODO(smp): before enabling concurrent scheduler access, replace raw context
// pairs with a per-CPU ownership protocol. A context pair outlives the lock,
// so another CPU must not mutate its thread slots during the switch.
struct ContextPair {
    old: *mut Context,
    new: *const Context,
}

struct TrapContextPair {
    old: *mut Context,
    new: *const Context,
    old_fp: *mut ThreadFpState,
    new_fp: *const ThreadFpState,
}

impl Thread {
    const fn new(
        id: ThreadId,
        process: ProcessId,
        weight: NonZeroU32,
        idle: bool,
        context: Context,
        stack: Option<KernelStack>,
    ) -> Self {
        Self {
            id,
            process,
            state: ThreadState::Ready,
            context,
            fp: ThreadFpState::new(),
            stack,
            blocked_on: None,
            weight,
            virtual_runtime: 0,
            process_next: None,
            idle,
        }
    }

    const fn snapshot(&self) -> ThreadSnapshot {
        ThreadSnapshot {
            id: self.id,
            process: self.process,
            state: self.state,
            weight: self.weight,
            virtual_runtime: self.virtual_runtime,
            blocked_on: self.blocked_on,
        }
    }
}

struct Scheduler<const THREADS: usize, const PROCESSES: usize> {
    threads: [Option<Thread>; THREADS],
    processes: [Option<Process>; PROCESSES],
    boot_context: Context,
    next_thread_id: u32,
    next_process_id: u32,
    current: Option<ThreadId>,
    idle: Option<ThreadId>,
    min_virtual_runtime: u64,
    need_reschedule: bool,
    initialized: bool,
    trace: Ring<TRACE_EVENTS>,
}

impl<const THREADS: usize, const PROCESSES: usize> Scheduler<THREADS, PROCESSES> {
    const fn new() -> Self {
        Self {
            threads: [const { None }; THREADS],
            processes: [None; PROCESSES],
            boot_context: Context::empty(),
            next_thread_id: 1,
            next_process_id: 1,
            current: None,
            idle: None,
            min_virtual_runtime: 0,
            need_reschedule: false,
            initialized: false,
            trace: Ring::new(),
        }
    }

    fn init(&mut self) -> Result<(), InitError> {
        self.reset();
        let kernel = self.create_process()?;
        let idle = self.create_thread(kernel, NonZeroU32::new(SCHED_MIN_WEIGHT).unwrap(), true)?;
        self.idle = Some(idle);
        self.current = Some(idle);
        if let Some(idle_thread) = self.thread_mut(idle) {
            idle_thread.state = ThreadState::Running;
        }
        self.initialized = true;
        Ok(())
    }

    fn init_with_idle_thread(
        &mut self,
        stack: KernelStack,
        entry: ThreadEntry,
        arg: usize,
    ) -> Result<(), InitError> {
        self.reset();
        let kernel = self.create_process()?;
        let idle = self.create_thread_with_stack(
            kernel,
            NonZeroU32::new(SCHED_MIN_WEIGHT).unwrap(),
            true,
            stack,
            entry,
            arg,
        )?;
        self.idle = Some(idle);
        self.current = Some(idle);
        if let Some(idle_thread) = self.thread_mut(idle) {
            idle_thread.state = ThreadState::Running;
        }
        self.initialized = true;
        Ok(())
    }

    fn create_process(&mut self) -> Result<ProcessId, InitError> {
        let id = ProcessId(self.next_process_id);
        self.next_process_id = self.next_process_id.wrapping_add(1).max(1);
        let Some(slot) = self.processes.iter_mut().find(|slot| slot.is_none()) else {
            return Err(InitError::ProcessTableFull);
        };
        *slot = Some(Process::new(id));
        Ok(id)
    }

    fn reset(&mut self) {
        for thread in &mut self.threads {
            *thread = None;
        }
        self.processes = [None; PROCESSES];
        self.boot_context = Context::empty();
        self.next_thread_id = 1;
        self.next_process_id = 1;
        self.current = None;
        self.idle = None;
        self.min_virtual_runtime = 0;
        self.need_reschedule = false;
        self.initialized = false;
        self.trace = Ring::new();
    }

    fn create_thread(
        &mut self,
        process_id: ProcessId,
        weight: NonZeroU32,
        idle: bool,
    ) -> Result<ThreadId, InitError> {
        self.insert_thread(process_id, weight, idle, Context::empty(), None)
    }

    fn create_thread_with_stack(
        &mut self,
        process_id: ProcessId,
        weight: NonZeroU32,
        idle: bool,
        stack: KernelStack,
        entry: ThreadEntry,
        arg: usize,
    ) -> Result<ThreadId, InitError> {
        let mut context = Context::new(
            crate::context::thread_trampoline_address(),
            stack.top().get(),
        );
        context.set_entry_data(entry as *const () as usize, arg);
        self.insert_thread(process_id, weight, idle, context, Some(stack))
    }

    fn insert_thread(
        &mut self,
        process_id: ProcessId,
        weight: NonZeroU32,
        idle: bool,
        context: Context,
        stack: Option<KernelStack>,
    ) -> Result<ThreadId, InitError> {
        let id = ThreadId(self.next_thread_id);
        self.next_thread_id = self.next_thread_id.wrapping_add(1).max(1);
        let Some(process_index) = self.process_index(process_id) else {
            return Err(InitError::ProcessTableFull);
        };
        let Some(thread_index) = self.threads.iter().position(Option::is_none) else {
            return Err(InitError::ThreadTableFull);
        };

        let mut thread = Thread::new(id, process_id, weight, idle, context, stack);
        self.processes[process_index]
            .as_mut()
            .expect("process index was found")
            .add_thread(&mut thread);
        // Start at the current runtime floor. Starting at zero would let a new
        // thread run until it caught up with time charged before it existed.
        if !idle && thread.virtual_runtime < self.min_virtual_runtime {
            thread.virtual_runtime = self.min_virtual_runtime;
        }
        self.threads[thread_index] = Some(thread);
        if !idle {
            self.trace(TraceKind::SchedEnqueue, id, 0, 0);
        }
        Ok(id)
    }

    fn current(&self) -> Option<ThreadSnapshot> {
        self.current
            .and_then(|id| self.thread(id))
            .map(Thread::snapshot)
    }

    fn thread(&self, id: ThreadId) -> Option<&Thread> {
        self.threads.iter().flatten().find(|thread| thread.id == id)
    }

    fn tick(&mut self, elapsed_ticks: u64) -> Result<bool, ScheduleError> {
        if elapsed_ticks == 0 {
            return Ok(self.need_reschedule);
        }
        if !self.initialized {
            return Err(ScheduleError::NotInitialized);
        }
        let current = self.current.ok_or(ScheduleError::NotInitialized)?;
        let (current_id, current_runtime, is_idle) = {
            let thread = self
                .thread_mut(current)
                .ok_or(ScheduleError::UnknownThread)?;
            if !thread.idle {
                let delta = scaled_vruntime_delta(elapsed_ticks, thread.weight);
                thread.virtual_runtime = thread.virtual_runtime.saturating_add(delta);
            }
            (thread.id, thread.virtual_runtime, thread.idle)
        };
        self.trace(TraceKind::SchedTick, current_id, 0, current_runtime);

        if let Some(best) = self
            .best_ready_thread()
            .map(|thread| (thread.id, thread.virtual_runtime))
        {
            let (_, best_runtime) = best;
            if is_idle || current_runtime > best_runtime {
                self.need_reschedule = true;
            }
            let current_min = if is_idle { u64::MAX } else { current_runtime };
            let next_min = core::cmp::min(best_runtime, current_min);
            if next_min > self.min_virtual_runtime {
                self.min_virtual_runtime = next_min;
            }
        } else if !is_idle && current_runtime > self.min_virtual_runtime {
            self.min_virtual_runtime = current_runtime;
        }

        Ok(self.need_reschedule)
    }

    #[cfg(test)]
    fn block_current(&mut self, wait: WaitToken) -> Result<Option<Switch>, ScheduleError> {
        let current = self.current.ok_or(ScheduleError::NotInitialized)?;
        let thread = self
            .thread_mut(current)
            .ok_or(ScheduleError::UnknownThread)?;
        thread.blocked_on = Some(wait);
        thread.state = ThreadState::Blocked;
        self.trace(TraceKind::SchedBlock, current, 0, wait.get() as u64);
        Ok(self.schedule())
    }

    #[cfg(test)]
    fn wake(&mut self, id: ThreadId) -> Result<(), ScheduleError> {
        let min_virtual_runtime = self.min_virtual_runtime;
        let thread = self.thread_mut(id).ok_or(ScheduleError::UnknownThread)?;
        if thread.state == ThreadState::Blocked {
            thread.blocked_on = None;
            thread.state = ThreadState::Ready;
            if thread.virtual_runtime < min_virtual_runtime {
                thread.virtual_runtime = min_virtual_runtime;
            }
            self.trace(TraceKind::SchedWake, id, 0, 0);
        }
        Ok(())
    }

    fn trace_len(&self) -> usize {
        self.trace.len()
    }

    fn enter_idle_contexts(&mut self) -> Result<ContextPair, ScheduleError> {
        if !self.initialized {
            return Err(ScheduleError::NotInitialized);
        }
        let idle = self.idle.ok_or(ScheduleError::NotInitialized)?;
        let old = &raw mut self.boot_context;
        let new = {
            let Some(idle_thread) = self.thread_mut(idle) else {
                return Err(ScheduleError::UnknownThread);
            };
            if idle_thread.stack.is_none() {
                return Err(ScheduleError::UnknownThread);
            }
            idle_thread.state = ThreadState::Running;
            &raw const idle_thread.context
        };
        self.current = Some(idle);
        Ok(ContextPair { old, new })
    }

    fn preempt_contexts(&mut self) -> Result<Option<TrapContextPair>, ScheduleError> {
        if !self.initialized {
            return Err(ScheduleError::NotInitialized);
        }
        if !self.need_reschedule {
            return Ok(None);
        }
        self.need_reschedule = false;
        let Some(switch) = self.schedule() else {
            return Ok(None);
        };
        self.trace(
            TraceKind::SchedPreempt,
            switch.previous,
            u64::from(switch.next.get()),
            0,
        );
        let (old, old_fp) = {
            let previous = self
                .thread_mut(switch.previous)
                .ok_or(ScheduleError::UnknownThread)?;
            (&raw mut previous.context, &raw mut previous.fp)
        };
        let (new, new_fp) = {
            let next = self
                .thread(switch.next)
                .ok_or(ScheduleError::UnknownThread)?;
            (&raw const next.context, &raw const next.fp)
        };
        Ok(Some(TrapContextPair {
            old,
            new,
            old_fp,
            new_fp,
        }))
    }

    fn schedule(&mut self) -> Option<Switch> {
        let previous = self.current?;
        let next = self
            .best_ready_thread()
            .map(|thread| thread.id)
            .or(self.idle)?;
        if previous == next {
            return None;
        }
        if let Some(previous_thread) = self.thread_mut(previous)
            && previous_thread.state == ThreadState::Running
        {
            previous_thread.state = ThreadState::Ready;
        }
        if let Some(next_thread) = self.thread_mut(next) {
            next_thread.state = ThreadState::Running;
        }
        self.current = Some(next);
        self.trace(TraceKind::SchedSwitch, previous, u64::from(next.get()), 0);
        Some(Switch { previous, next })
    }

    fn best_ready_thread(&self) -> Option<&Thread> {
        self.threads
            .iter()
            .flatten()
            .filter(|thread| thread.state == ThreadState::Ready && !thread.idle)
            .min_by_key(|thread| (thread.virtual_runtime, thread.id.0))
    }

    fn thread_mut(&mut self, id: ThreadId) -> Option<&mut Thread> {
        self.threads
            .iter_mut()
            .flatten()
            .find(|thread| thread.id == id)
    }

    fn process_index(&self, id: ProcessId) -> Option<usize> {
        self.processes.iter().position(|process| {
            process.is_some_and(|process| process.id == id && process.state == ProcessState::Active)
        })
    }

    fn trace(&mut self, kind: TraceKind, subject: ThreadId, object: u64, value: u64) {
        self.trace.emit(TraceEvent {
            kind,
            subject: u64::from(subject.get()),
            object,
            value,
        });
    }
}

impl<const THREADS: usize, const PROCESSES: usize> Default for Scheduler<THREADS, PROCESSES> {
    fn default() -> Self {
        Self::new()
    }
}

// Protects thread/process records, run state, and scheduler trace events.
// Context transfers release this lock before changing stacks; ContextPair and
// TrapContextPair describe the current single-CPU ownership constraint.
static SCHEDULER: Locked<Scheduler<MAX_TASKS, MAX_PROCESSES>> = Locked::new(Scheduler::new());

pub fn init() -> Result<(), InitError> {
    SCHEDULER.lock().init()
}

pub fn init_with_idle_thread(
    stack: KernelStack,
    entry: ThreadEntry,
    arg: usize,
) -> Result<(), InitError> {
    SCHEDULER.lock().init_with_idle_thread(stack, entry, arg)
}

pub fn enter_idle(switch_context: ContextSwitch) -> Result<(), ScheduleError> {
    let pair = { SCHEDULER.lock().enter_idle_contexts()? };
    // SAFETY: The scheduler returned the boot context it owns.
    let old = unsafe { &mut *pair.old };
    // SAFETY: The new context belongs to the idle thread and has a live
    // guard-mapped kernel stack.
    let new = unsafe { &*pair.new };
    // SAFETY: The scheduler owns both contexts and checked the target stack.
    unsafe { switch_context(old, new) };
    Ok(())
}

pub fn preempt_from_trap<S: TrapContextSwitch>() -> Result<(), ScheduleError> {
    // TODO(synchronous-ipc): reuse this paired FP/integer transfer for every
    // blocking or yielding switch from a syscall trap. No path may switch
    // stacks while leaving FP ownership attached to the outgoing thread.
    let Some(pair) = ({ SCHEDULER.lock().preempt_contexts()? }) else {
        return Ok(());
    };
    // The incoming thread must be able to take SCHEDULER's lock. The temporary
    // guard above is already dropped; trap entry keeps local interrupts disabled
    // until the transfer finishes. Secondary CPUs are not scheduled yet.
    // TODO(process-creation): add a QEMU regression that alternates distinct FP
    // values between two user threads on both architectures.
    {
        // SAFETY: A real scheduler switch returns distinct outgoing and incoming
        // threads. Trap entry disabled hardware FP access, and interrupts remain
        // disabled while the architecture transfers their resident FP state.
        let old_fp = unsafe { &mut *pair.old_fp };
        // SAFETY: The selected thread remains stored in the scheduler while its
        // saved FP image is read for the incoming CPU context.
        let new_fp = unsafe { &*pair.new_fp };
        // SAFETY: The scheduler proved that these FP states belong to the same
        // outgoing and incoming threads as the context pair below.
        unsafe { S::switch_fp(old_fp, new_fp) };
    }
    // SAFETY: The scheduler returned the outgoing thread context it owns.
    let old = unsafe { &mut *pair.old };
    // SAFETY: The scheduler returned the selected runnable thread context.
    let new = unsafe { &*pair.new };
    // SAFETY: The trap frame remains on the outgoing thread's stack while this
    // software context switch saves callee-saved state and changes stacks.
    unsafe { S::switch_integer(old, new) };
    Ok(())
}

/// Charges elapsed scheduler intervals to the current thread and reports
/// whether a reschedule is pending. Does not switch contexts itself.
///
/// Pass [`crate::clock::TickAdvance::elapsed_ticks`], not raw hardware counter ticks.
pub fn tick(elapsed_ticks: u64) -> Result<bool, ScheduleError> {
    SCHEDULER.lock().tick(elapsed_ticks)
}

pub fn current() -> Option<ThreadSnapshot> {
    SCHEDULER.lock().current()
}

/// Enables the current thread's saved FP image and inspects it in place.
///
/// The scheduler holds its lock while the callback runs. The callback must
/// not re-enter task APIs. Borrowing the state avoids copying the entire
/// architecture register image when the thread first uses FP.
pub fn enable_current_user_fp_state(
    activate: impl FnOnce(&ThreadFpState),
) -> Result<(), ScheduleError> {
    let mut scheduler = SCHEDULER.lock();
    let current = scheduler.current.ok_or(ScheduleError::NoCurrentThread)?;
    let thread = scheduler
        .thread_mut(current)
        .ok_or(ScheduleError::UnknownThread)?;
    debug_assert_eq!(thread.id, current);
    thread.fp.enable_user_state();
    activate(&thread.fp);
    Ok(())
}

/// Inspects the current thread's FP state without letting its reference escape
/// the scheduler lock.
///
/// The callback runs with the lock held and must not re-enter task APIs.
pub fn with_current_user_fp_state<R>(
    inspect: impl FnOnce(&ThreadFpState) -> R,
) -> Result<R, ScheduleError> {
    let scheduler = SCHEDULER.lock();
    let current = scheduler.current.ok_or(ScheduleError::NoCurrentThread)?;
    let thread = scheduler
        .threads
        .iter()
        .flatten()
        .find(|thread| thread.id == current)
        .ok_or(ScheduleError::UnknownThread)?;
    Ok(inspect(&thread.fp))
}

/// Returns the initial kernel process while bootstrapping kernel-owned threads.
pub fn bootstrap_process() -> Option<BootstrapProcess> {
    SCHEDULER
        .lock()
        .processes
        .iter()
        .flatten()
        .next()
        .map(|process| BootstrapProcess { id: process.id })
}

pub fn create_thread_with_stack(
    process: BootstrapProcess,
    weight: NonZeroU32,
    stack: KernelStack,
    entry: ThreadEntry,
    arg: usize,
) -> Result<ThreadId, InitError> {
    process.spawn(weight, stack, entry, arg)
}

pub fn trace_len() -> usize {
    SCHEDULER.lock().trace_len()
}

#[cfg(test)]
fn find_thread_mut(threads: &mut [Option<Thread>], id: ThreadId) -> Option<&mut Thread> {
    threads.iter_mut().flatten().find(|thread| thread.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracks_process_threads_without_raw_public_pointers() {
        let mut scheduler = Scheduler::<4, 2>::new();
        let process = scheduler.create_process().unwrap();
        let first = scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();
        let second = scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();
        let process_index = scheduler.process_index(process).unwrap();

        assert_eq!(scheduler.processes[process_index].unwrap().thread_count, 2);
        assert!(
            !scheduler.processes[process_index]
                .as_mut()
                .unwrap()
                .remove_thread(second, &mut scheduler.threads)
        );
        assert!(
            scheduler.processes[process_index]
                .as_mut()
                .unwrap()
                .remove_thread(first, &mut scheduler.threads)
        );
    }

    #[test]
    fn vruntime_scales_inversely_with_weight() {
        let mut scheduler = Scheduler::<4, 2>::new();
        scheduler.init().unwrap();
        let process = scheduler.create_process().unwrap();
        let normal = scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();
        let high = scheduler
            .create_thread(
                process,
                NonZeroU32::new(SCHED_BASE_WEIGHT * 2).unwrap(),
                false,
            )
            .unwrap();

        scheduler.current = Some(normal);
        scheduler.thread_mut(normal).unwrap().state = ThreadState::Running;
        scheduler.tick(1).unwrap();
        scheduler.current = Some(high);
        scheduler.thread_mut(high).unwrap().state = ThreadState::Running;
        scheduler.tick(1).unwrap();

        assert_eq!(
            scheduler.thread(normal).unwrap().virtual_runtime,
            SCHED_TIME_SLICE_NS
        );
        assert_eq!(
            scheduler.thread(high).unwrap().virtual_runtime,
            SCHED_TIME_SLICE_NS / 2
        );
    }

    #[test]
    fn default_weight_uses_unscaled_elapsed_time() {
        let weight = NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap();

        assert_eq!(scaled_vruntime_delta(3, weight), SCHED_TIME_SLICE_NS * 3);
    }

    #[test]
    fn idle_tick_requests_a_switch_without_charging_idle_runtime() {
        let mut scheduler = Scheduler::<4, 2>::new();
        scheduler.init().unwrap();
        let idle = scheduler.idle.unwrap();
        let process = scheduler.create_process().unwrap();
        scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();

        assert!(scheduler.tick(1).unwrap());
        assert_eq!(scheduler.thread(idle).unwrap().virtual_runtime, 0);
    }

    #[test]
    fn preemption_pairs_fp_state_with_the_same_threads_as_integer_contexts() {
        let mut scheduler = Scheduler::<4, 2>::new();
        scheduler.init().unwrap();
        let idle = scheduler.idle.unwrap();
        let process = scheduler.create_process().unwrap();
        let next = scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();
        scheduler.thread_mut(next).unwrap().fp.enable_user_state();
        let expected_old_fp = scheduler.thread(idle).unwrap().fp;
        let expected_new_fp = scheduler.thread(next).unwrap().fp;

        scheduler.need_reschedule = true;
        let pair = scheduler.preempt_contexts().unwrap().unwrap();

        // SAFETY: The pair points into `scheduler`; it has not been mutated or
        // moved since `preempt_contexts` returned.
        assert_eq!(unsafe { *pair.old_fp }, expected_old_fp);
        // SAFETY: The same scheduler ownership and lifetime argument applies.
        assert_eq!(unsafe { *pair.new_fp }, expected_new_fp);
        assert_eq!(scheduler.current, Some(next));
    }

    #[test]
    fn blocks_and_wakes_thread() {
        let mut scheduler = Scheduler::<4, 2>::new();
        scheduler.init().unwrap();
        let process = scheduler.create_process().unwrap();
        let thread = scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();
        scheduler.current = Some(thread);
        scheduler.thread_mut(thread).unwrap().state = ThreadState::Running;

        scheduler
            .block_current(WaitToken::new(0x1000).unwrap())
            .unwrap();
        assert_eq!(
            scheduler.thread(thread).unwrap().state,
            ThreadState::Blocked
        );
        scheduler.wake(thread).unwrap();
        assert_eq!(scheduler.thread(thread).unwrap().state, ThreadState::Ready);
    }

    #[test]
    fn trace_ring_records_scheduler_events() {
        let mut scheduler = Scheduler::<4, 2>::new();
        scheduler.init().unwrap();
        let process = scheduler.create_process().unwrap();
        let thread = scheduler
            .create_thread(process, NonZeroU32::new(SCHED_BASE_WEIGHT).unwrap(), false)
            .unwrap();
        scheduler.current = Some(thread);
        scheduler.thread_mut(thread).unwrap().state = ThreadState::Running;
        scheduler.tick(1).unwrap();

        assert!(scheduler.trace_len() >= 2);
    }

    #[test]
    fn kernel_stack_top_is_base_plus_size() {
        let stack = KernelStack::new_for_test(VirtualAddress::new(0xffff_0000), KERNEL_STACK_SIZE);

        assert_eq!(stack.base(), VirtualAddress::new(0xffff_0000));
        assert_eq!(
            stack.top(),
            VirtualAddress::new(0xffff_0000 + KERNEL_STACK_SIZE)
        );
    }

    #[test]
    fn idle_thread_owns_stack_and_entry_context() {
        extern "C" fn idle_entry(_: usize) -> ! {
            loop {
                core::hint::spin_loop();
            }
        }

        let mut scheduler = Scheduler::<4, 2>::new();
        let stack = KernelStack::new_for_test(VirtualAddress::new(0x8000), KERNEL_STACK_SIZE);
        scheduler
            .init_with_idle_thread(stack, idle_entry, 0x55)
            .unwrap();

        let idle = scheduler.idle.unwrap();
        let thread = scheduler.thread(idle).unwrap();
        assert!(thread.stack.is_some());
        assert_eq!(thread.context.stack_pointer(), 0x8000 + KERNEL_STACK_SIZE);
    }
}
