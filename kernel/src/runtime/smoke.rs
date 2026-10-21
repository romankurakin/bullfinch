//! QEMU regression checks enabled only by the smoke-test build feature.
//!
//! Two kernel threads exchange progress through atomics without yielding.
//! Both must start and resume after timer preemption before reporting success.

use core::{
    num::NonZeroU32,
    sync::atomic::{AtomicUsize, Ordering},
};

use kernel::{cpu, task};

use crate::{console, hal};

static PROGRESS: [AtomicUsize; 2] = [const { AtomicUsize::new(0) }; 2];
static COMPLETED: AtomicUsize = AtomicUsize::new(0);

#[cfg(feature = "stack-overflow-test")]
static OVERFLOW_NEIGHBOR: AtomicUsize = AtomicUsize::new(0);

pub fn start() {
    // Publish both runnable threads before either can preempt this setup.
    // Nested allocator and scheduler guards preserve the masked IRQ state.
    let irq_was_enabled = cpu::disable_interrupts();
    let process = task::bootstrap_process().expect("smoke: bootstrap process exists");
    for index in 0..PROGRESS.len() {
        let stack = task::KernelStack::create_mapped(
            hal::mmu::kernel_stack_region_base,
            hal::mmu::map_kernel_stack_page,
            hal::mmu::unmap_kernel_stack_page,
        )
        .expect("smoke: worker stack allocation failed");
        process
            .spawn(
                NonZeroU32::new(task::SCHED_BASE_WEIGHT).unwrap(),
                stack,
                worker,
                index,
            )
            .expect("smoke: worker creation failed");
    }
    cpu::restore_interrupts(irq_was_enabled);
}

extern "C" fn worker(index: usize) -> ! {
    let irq_was_enabled = cpu::disable_interrupts();
    if !irq_was_enabled {
        fail("worker started with interrupts disabled");
    }
    cpu::restore_interrupts(irq_was_enabled);

    let peer = 1 - index;
    for round in 1..=2 {
        PROGRESS[index].store(round, Ordering::Release);
        let deadline = hal::timer::now()
            .get()
            .checked_add(
                hal::timer::frequency()
                    .expect("smoke: timer is ready")
                    .get(),
            )
            .expect("smoke: deadline overflow");
        while PROGRESS[peer].load(Ordering::Acquire) < round {
            if hal::timer::now().get() >= deadline {
                fail("timer preemption did not resume both workers");
            }
            core::hint::spin_loop();
        }
    }

    if COMPLETED.fetch_add(1, Ordering::AcqRel) == PROGRESS.len() - 1 {
        console::print_unsafe("[SCHED:OK]\n");
        #[cfg(feature = "stack-overflow-test")]
        run_stack_overflow_test();
    }
    // Thread exit is not implemented yet. Keep the test stacks owned and let
    // the host terminate QEMU after inspecting the completion marker.
    hal::cpu::halt()
}

#[cfg(feature = "stack-overflow-test")]
fn run_stack_overflow_test() -> ! {
    cpu::disable_interrupts();
    let create_stack = || {
        task::KernelStack::create_mapped(
            hal::mmu::kernel_stack_region_base,
            hal::mmu::map_kernel_stack_page,
            hal::mmu::unmap_kernel_stack_page,
        )
        .expect("smoke: overflow stack allocation failed")
    };
    let neighbor = create_stack();
    let target = create_stack();
    assert_eq!(
        neighbor.base().get() + task::KERNEL_STACK_SLOT_SIZE,
        target.base().get(),
        "smoke: overflow stacks must be adjacent"
    );
    for offset in 0..neighbor.size() {
        // SAFETY: This mapped stack is exclusively owned and has no thread.
        unsafe {
            (neighbor.base().get() as *mut u8)
                .add(offset)
                .write_volatile(0xa5)
        };
    }
    OVERFLOW_NEIGHBOR.store(neighbor.base().get(), Ordering::Release);
    #[cfg(feature = "stack-overflow-irq-test")]
    let stack_pointer = target.base().get() + 16;
    #[cfg(not(feature = "stack-overflow-irq-test"))]
    let stack_pointer = target.base().get() - task::KERNEL_STACK_GUARD_SIZE;
    core::mem::forget(neighbor);
    core::mem::forget(target);
    // SAFETY: Both adjacent slots stay owned until QEMU stops. The deliberate
    // fault must reach the emergency stack without writing into the neighbor.
    unsafe { crate::arch::trap::trigger_stack_overflow_test(stack_pointer) }
}

#[cfg(feature = "stack-overflow-test")]
pub fn overflow_neighbor_intact() -> bool {
    let base = OVERFLOW_NEIGHBOR.load(Ordering::Acquire);
    if base == 0 {
        return false;
    }
    (0..task::KERNEL_STACK_SIZE).all(|offset| {
        // SAFETY: The test retained this initialized, mapped stack, and no
        // thread uses it. Only an overflowing trap entry could change it.
        unsafe { (base as *const u8).add(offset).read_volatile() == 0xa5 }
    })
}

fn fail(message: &str) -> ! {
    // The panic handler masks interrupts, so another worker cannot report
    // success after a failed check.
    panic!("[SCHED:FAIL] {message}")
}
