#![no_std]
#![no_main]

use core::panic::PanicInfo;

mod arch;
mod console;
mod hal;
mod runtime;
mod startup;

use kernel::{boot, mmu::PhysicalAddress};

#[cfg(target_arch = "riscv64")]
#[used]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".data.boot")]
static BOOT_HART_CLAIM: BootHartClaim = BootHartClaim::new();

#[cfg(target_arch = "riscv64")]
#[repr(transparent)]
struct BootHartClaim(core::cell::UnsafeCell<usize>);

#[cfg(target_arch = "riscv64")]
// SAFETY: The boot stub mutates this word with an atomic AMO before Rust
// shared state exists. Rust code never takes references to the inner value.
unsafe impl Sync for BootHartClaim {}

#[cfg(target_arch = "riscv64")]
impl BootHartClaim {
    const fn new() -> Self {
        Self(core::cell::UnsafeCell::new(0))
    }
}

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    console::print_unsafe("\n[PANIC]\n");
    hal::cpu::halt()
}

/// `boot_hart` is `Some` on RISC-V (OpenSBI passes `mhartid` in `a0`) and
/// `None` on ARM64 (the boot stub only brings up the primary core).
pub struct BootInfo {
    pub boot_hart: Option<boot::HartId>,
    pub dtb: boot::DeviceTreeBlobPhysicalAddress,
}

unsafe extern "C" {
    static __kernel_end: u8;
}

/// Never returns. On failure it prints a message and halts. It avoids panicking
/// because panic formatting may depend on subsystems that are not ready yet.
pub fn kernel_main(info: BootInfo) -> ! {
    let mut out = console::Console::new();
    let hardware = match startup::init::virt_init(info.dtb) {
        Ok(hardware) => hardware,
        Err(_) => {
            out.print("\n[PANIC]\nboot: invalid device tree\n");
            hal::cpu::halt();
        }
    };

    kernel::pmm::init(
        &hardware,
        hal::mmu::KERNEL_PHYSICAL_LOAD,
        kernel_physical_end(),
        hal::mmu::physical_to_virtual,
    )
    .unwrap_or_else(|_| {
        out.print("\n[PANIC]\npmm: initialization failed\n");
        hal::cpu::halt();
    });
    startup::log::pmm();
    kernel::allocator::init(hal::mmu::physical_to_virtual, hal::mmu::virtual_to_physical);
    kernel::allocator::boot_probe().unwrap_or_else(|_| {
        out.print("\n[PANIC]\nallocator: initialization failed\n");
        hal::cpu::halt();
    });
    let idle_stack = kernel::task::KernelStack::create_mapped(
        hal::mmu::kernel_stack_region_base,
        hal::mmu::map_kernel_stack_page,
        hal::mmu::unmap_kernel_stack_page,
    )
    .unwrap_or_else(|_| {
        out.print("\n[PANIC]\ntask: idle stack allocation failed\n");
        hal::cpu::halt();
    });
    kernel::task::init_with_idle_thread(idle_stack, idle_thread, 0).unwrap_or_else(|_| {
        out.print("\n[PANIC]\ntask: scheduler initialization failed\n");
        hal::cpu::halt();
    });
    startup::log::trace();
    hal::interrupt::init(&hardware);
    runtime::clock::init().unwrap_or_else(|_| {
        out.print("\n[PANIC]\nclock: invalid timer frequency\n");
        hal::cpu::halt();
    });
    hal::timer::enable().unwrap_or_else(|_| {
        out.print("\n[PANIC]\nclock: timer enable failed\n");
        hal::cpu::halt();
    });
    runtime::clock::wait_for_first_tick(100_000_000).unwrap_or_else(|_| {
        out.print("\n[PANIC]\nclock: first timer interrupt did not arrive\n");
        hal::cpu::halt();
    });
    startup::log::clock();
    startup::log::task();
    startup::log::idle();
    out.print("[BOOT:OK]\n");

    enter_idle_thread(&mut out)
}

fn kernel_physical_end() -> PhysicalAddress {
    let end_virtual = core::ptr::addr_of!(__kernel_end) as usize;
    hal::mmu::virtual_to_physical(kernel::mmu::VirtualAddress::new(end_virtual))
}

fn enter_idle_thread(out: &mut console::Console) -> ! {
    kernel::task::enter_idle(switch_context).unwrap_or_else(|_| {
        out.print("\n[PANIC]\ntask: idle context missing\n");
        hal::cpu::halt();
    });

    out.print("\n[PANIC]\ntask: idle thread returned\n");
    hal::cpu::halt()
}

unsafe fn switch_context(old: &mut hal::context::Context, new: &hal::context::Context) {
    // SAFETY: `kernel::task` owns both contexts and checks that the target
    // thread has a live stack before handing control to this architecture call.
    unsafe { hal::context::switch_context(old, new) };
}

extern "C" fn idle_thread(_: usize) -> ! {
    hal::cpu::halt()
}
