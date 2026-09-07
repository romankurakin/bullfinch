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
    }
    // Thread exit is not implemented yet. Keep the test stacks owned and let
    // the host terminate QEMU after inspecting the completion marker.
    hal::cpu::halt()
}

fn fail(message: &str) -> ! {
    // Stop this single-CPU test on failure so another worker cannot report
    // success after a failed check.
    cpu::disable_interrupts();
    console::print_unsafe("[SCHED:FAIL] ");
    console::print_unsafe(message);
    console::print_unsafe("\n");
    hal::cpu::halt()
}
