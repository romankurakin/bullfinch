//! Task and scheduler model.
//!
//! Threads are represented by opaque IDs and stored inside the scheduler. This
//! keeps ownership local to the scheduler and avoids exporting raw thread
//! pointers before the context-switching rung grows real stacks.

use core::{
    num::NonZeroU32,
    sync::atomic::{AtomicUsize, Ordering},
};

use crate::{
    clock,
    context::Context,
    limits::MAX_TASKS,
    mmu::{MapError, PAGE_SIZE, PhysicalAddress, UnmapError, VirtualAddress},
    pmm::{self, PageRun},
    sync::SpinLock,
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

static NEXT_STACK_SLOT: AtomicUsize = AtomicUsize::new(0);

pub type KernelStackRegionBase = fn() -> VirtualAddress;
pub type MapKernelStackPage = fn(VirtualAddress, PhysicalAddress) -> Result<(), MapError>;
pub type UnmapKernelStackPage = fn(VirtualAddress) -> Result<PhysicalAddress, UnmapError>;
pub type ThreadEntry = extern "C" fn(usize) -> !;
pub type ContextSwitch = unsafe fn(&mut Context, &Context);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StackError {
    OutOfMemory,
    AddressNotMapped,
    RegionExhausted,
    Map(MapError),
}

pub struct KernelStack {
    pages: PageRun,
    base: VirtualAddress,
    size: usize,
    unmap: Option<UnmapKernelStackPage>,
}

impl KernelStack {
    pub fn create_mapped(
        stack_region_base: KernelStackRegionBase,
        map_page: MapKernelStackPage,
        unmap_page: UnmapKernelStackPage,
    ) -> Result<Self, StackError> {
        let slot = NEXT_STACK_SLOT.fetch_add(1, Ordering::Relaxed);
        if slot >= MAX_KERNEL_STACK_SLOTS {
            return Err(StackError::RegionExhausted);
        }

        let pages = pmm::alloc_contiguous(KERNEL_STACK_PAGES, PAGE_ALIGNMENT_LOG2)
            .ok_or(StackError::OutOfMemory)?;
        let base = stack_region_base()
            .checked_add(
                slot.checked_mul(KERNEL_STACK_SLOT_SIZE)
                    .and_then(|offset| offset.checked_add(KERNEL_STACK_GUARD_SIZE))
                    .ok_or(StackError::RegionExhausted)?,
            )
            .ok_or(StackError::RegionExhausted)?;

        let mut mapped_pages = 0usize;
        while mapped_pages < KERNEL_STACK_PAGES {
            let Some(physical) = pages.physical_address(mapped_pages) else {
                rollback_stack_mapping(base, mapped_pages, unmap_page);
                return Err(StackError::AddressNotMapped);
            };
            let virtual_address = base
                .checked_add(mapped_pages * PAGE_SIZE)
                .ok_or(StackError::RegionExhausted)?;
            if let Err(error) = map_page(virtual_address, physical) {
                rollback_stack_mapping(base, mapped_pages, unmap_page);
                return Err(StackError::Map(error));
            }
            mapped_pages += 1;
        }

        Ok(Self {
            pages,
            base,
            size: KERNEL_STACK_SIZE,
            unmap: Some(unmap_page),
        })
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
            pages: PageRun::new_for_test(),
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
            rollback_stack_mapping(self.base, KERNEL_STACK_PAGES, unmap_page);
        }
        let _ = self.pages.count();
    }
}

fn rollback_stack_mapping(
    base: VirtualAddress,
    mapped_pages: usize,
    unmap_page: UnmapKernelStackPage,
) {
    let mut index = mapped_pages;
    while index > 0 {
        index -= 1;
        if let Some(virtual_address) = base.checked_add(index * PAGE_SIZE) {
            let _ = unmap_page(virtual_address);
        }
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
    UnknownThread,
    ZeroWeight,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KernelProcess {
    id: ProcessId,
}

impl KernelProcess {
    pub fn spawn(
        self,
        weight: NonZeroU32,
        stack: KernelStack,
        entry: ThreadEntry,
        arg: usize,
    ) -> Result<ThreadId, InitError> {
        let _guard = SCHEDULER_LOCK.guard();
        scheduler().create_thread_with_stack(self.id, weight, false, stack, entry, arg)
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
    stack: Option<KernelStack>,
    blocked_on: Option<WaitToken>,
    weight: NonZeroU32,
    virtual_runtime: u64,
    process_next: Option<ThreadId>,
    idle: bool,
}

struct ContextPair {
    old: *mut Context,
    new: *const Context,
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
        *self = Self::new();
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
        *self = Self::new();
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

    fn tick(&mut self, elapsed_ticks: u64) -> Result<(), ScheduleError> {
        if elapsed_ticks == 0 {
            return Ok(());
        }
        if !self.initialized {
            return Err(ScheduleError::NotInitialized);
        }
        let current = self.current.ok_or(ScheduleError::NotInitialized)?;
        let (current_id, current_runtime, is_idle) = {
            let thread = self
                .thread_mut(current)
                .ok_or(ScheduleError::UnknownThread)?;
            let elapsed_ns = u128::from(SCHED_TIME_SLICE_NS) * u128::from(elapsed_ticks);
            let weight = u128::from(thread.weight.get());
            if weight == 0 {
                return Err(ScheduleError::ZeroWeight);
            }
            let scaled = elapsed_ns * u128::from(SCHED_BASE_WEIGHT) / weight;
            let delta = core::cmp::min(scaled, u128::from(u64::MAX)) as u64;
            thread.virtual_runtime = thread.virtual_runtime.saturating_add(delta);
            (thread.id, thread.virtual_runtime, thread.idle)
        };
        self.trace(TraceKind::SchedTick, current_id, 0, current_runtime);

        if let Some(best) = self
            .best_ready_thread()
            .map(|thread| (thread.id, thread.virtual_runtime))
        {
            let (_, best_runtime) = best;
            if current_runtime > best_runtime {
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

        Ok(())
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

    fn maybe_reschedule(&mut self) -> Option<Switch> {
        if !self.need_reschedule {
            return None;
        }
        self.need_reschedule = false;
        self.schedule()
    }

    fn trace_len(&self) -> usize {
        self.trace.len()
    }

    fn enter_idle_contexts(&mut self) -> Result<ContextPair, ScheduleError> {
        if !self.initialized {
            return Err(ScheduleError::NotInitialized);
        }
        let idle = self.idle.ok_or(ScheduleError::NotInitialized)?;
        let old = &mut self.boot_context as *mut Context;
        let new = {
            let Some(idle_thread) = self.thread_mut(idle) else {
                return Err(ScheduleError::UnknownThread);
            };
            if idle_thread.stack.is_none() {
                return Err(ScheduleError::UnknownThread);
            }
            idle_thread.state = ThreadState::Running;
            &idle_thread.context as *const Context
        };
        self.current = Some(idle);
        Ok(ContextPair { old, new })
    }

    fn preempt_contexts(&mut self) -> Result<Option<ContextPair>, ScheduleError> {
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
        let old = {
            let previous = self
                .thread_mut(switch.previous)
                .ok_or(ScheduleError::UnknownThread)?;
            &mut previous.context as *mut Context
        };
        let new = {
            let next = self
                .thread(switch.next)
                .ok_or(ScheduleError::UnknownThread)?;
            &next.context as *const Context
        };
        Ok(Some(ContextPair { old, new }))
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

struct SchedulerCell(core::cell::UnsafeCell<Scheduler<MAX_TASKS, MAX_PROCESSES>>);

// SAFETY: Access to the global scheduler is serialized by `SCHEDULER_LOCK`.
unsafe impl Sync for SchedulerCell {}

static SCHEDULER: SchedulerCell = SchedulerCell(core::cell::UnsafeCell::new(Scheduler::new()));
static SCHEDULER_LOCK: SpinLock = SpinLock::new();

pub fn init() -> Result<(), InitError> {
    let _guard = SCHEDULER_LOCK.guard();
    scheduler().init()
}

pub fn init_with_idle_thread(
    stack: KernelStack,
    entry: ThreadEntry,
    arg: usize,
) -> Result<(), InitError> {
    let _guard = SCHEDULER_LOCK.guard();
    scheduler().init_with_idle_thread(stack, entry, arg)
}

pub fn enter_idle(switch_context: ContextSwitch) -> Result<(), ScheduleError> {
    let pair = {
        let _guard = SCHEDULER_LOCK.guard();
        scheduler().enter_idle_contexts()?
    };
    // SAFETY: The scheduler returned contexts it owns. The new context belongs
    // to the idle thread and has a live guard-mapped kernel stack.
    unsafe { switch_context(&mut *pair.old, &*pair.new) };
    Ok(())
}

pub fn preempt_from_trap(switch_context: ContextSwitch) -> Result<(), ScheduleError> {
    let Some(pair) = ({
        let _guard = SCHEDULER_LOCK.guard();
        scheduler().preempt_contexts()?
    }) else {
        return Ok(());
    };
    // SAFETY: The trap frame remains on the outgoing thread's stack while this
    // software context switch saves callee-saved state and changes stacks.
    unsafe { switch_context(&mut *pair.old, &*pair.new) };
    Ok(())
}

pub fn tick(elapsed_ticks: u64) {
    let _guard = SCHEDULER_LOCK.guard();
    let _ = scheduler().tick(elapsed_ticks);
}

pub fn maybe_reschedule() -> Option<Switch> {
    let _guard = SCHEDULER_LOCK.guard();
    scheduler().maybe_reschedule()
}

pub fn current() -> Option<ThreadSnapshot> {
    let _guard = SCHEDULER_LOCK.guard();
    scheduler().current()
}

pub fn kernel_process() -> Option<KernelProcess> {
    let _guard = SCHEDULER_LOCK.guard();
    scheduler()
        .processes
        .iter()
        .flatten()
        .next()
        .map(|process| KernelProcess { id: process.id })
}

pub fn create_thread_with_stack(
    process: KernelProcess,
    weight: NonZeroU32,
    stack: KernelStack,
    entry: ThreadEntry,
    arg: usize,
) -> Result<ThreadId, InitError> {
    process.spawn(weight, stack, entry, arg)
}

pub fn trace_len() -> usize {
    let _guard = SCHEDULER_LOCK.guard();
    scheduler().trace_len()
}

fn scheduler() -> &'static mut Scheduler<MAX_TASKS, MAX_PROCESSES> {
    // SAFETY: Callers hold `SCHEDULER_LOCK`.
    unsafe { &mut *SCHEDULER.0.get() }
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
