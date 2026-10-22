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
static OVERFLOW_CANARY_BASE: AtomicUsize = AtomicUsize::new(0);
#[cfg(feature = "stack-overflow-test")]
static OVERFLOW_CANARY_LEN: AtomicUsize = AtomicUsize::new(0);

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
    #[cfg(not(feature = "boot-stack-overflow-test"))]
    let (canary_base, canary_len, stack_pointer) = {
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
        #[cfg(feature = "stack-overflow-irq-test")]
        let stack_pointer = target.base().get() + 16;
        #[cfg(not(feature = "stack-overflow-irq-test"))]
        let stack_pointer = target.base().get() - task::KERNEL_STACK_GUARD_SIZE;
        let region = (neighbor.base().get(), neighbor.size(), stack_pointer);
        core::mem::forget(neighbor);
        core::mem::forget(target);
        region
    };
    #[cfg(feature = "boot-stack-overflow-test")]
    let (canary_base, canary_len, stack_pointer) = {
        unsafe extern "C" {
            #[cfg(not(feature = "stack-overflow-irq-test"))]
            static __stack_guard: u8;
            static __stack_bottom: u8;
            static __stack_top: u8;
        }
        let bottom = core::ptr::addr_of!(__stack_bottom) as usize;
        let top = core::ptr::addr_of!(__stack_top) as usize;
        #[cfg(feature = "stack-overflow-irq-test")]
        let stack_pointer = bottom + 16;
        #[cfg(not(feature = "stack-overflow-irq-test"))]
        let stack_pointer = core::ptr::addr_of!(__stack_guard) as usize;
        (bottom, top - bottom, stack_pointer)
    };
    for offset in 0..canary_len {
        // SAFETY: The task fixture retains an unused owned stack. The boot
        // fixture uses the abandoned boot stack after scheduler startup.
        // Both regions stay mapped, and interrupts remain masked.
        unsafe { (canary_base as *mut u8).add(offset).write_volatile(0xa5) };
    }
    OVERFLOW_CANARY_LEN.store(canary_len, Ordering::Relaxed);
    OVERFLOW_CANARY_BASE.store(canary_base, Ordering::Release);
    // SAFETY: The selected stack stays reserved until QEMU stops. The
    // deliberate fault must reach the emergency stack without changing the
    // task neighbor or abandoned boot stack checked by the canary.
    unsafe { crate::arch::trap::trigger_stack_overflow_test(stack_pointer) }
}

#[cfg(feature = "stack-overflow-test")]
pub fn overflow_canary_intact() -> bool {
    let base = OVERFLOW_CANARY_BASE.load(Ordering::Acquire);
    let len = OVERFLOW_CANARY_LEN.load(Ordering::Relaxed);
    if base == 0 || len == 0 {
        return false;
    }
    (0..len).all(|offset| {
        // SAFETY: The test retained this initialized, mapped region, and no
        // thread uses it. Only an overflowing trap entry could change it.
        unsafe { (base as *const u8).add(offset).read_volatile() == 0xa5 }
    })
}

fn fail(message: &str) -> ! {
    // The panic handler masks interrupts, so another worker cannot report
    // success after a failed check.
    panic!("[SCHED:FAIL] {message}")
}
