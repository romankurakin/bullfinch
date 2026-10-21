#![no_std]
#![no_main]

use core::{
    fmt::Write as _,
    panic::PanicInfo,
    sync::atomic::{AtomicBool, Ordering},
};

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

/// Set once the kernel runs in the higher half.
///
/// Formatting a panic message reads the string tables behind `format_args!`
/// and trait vtables. They hold link-time virtual addresses, which are
/// unmapped before the higher-half jump. Until then the handler prints a
/// fixed marker, and the physical boot phase prints fixed strings.
static HIGHER_HALF: AtomicBool = AtomicBool::new(false);

/// Set by the first panic. A second panic, for example from a fault while
/// printing the first report, halts without touching the console again.
static PANICKING: AtomicBool = AtomicBool::new(false);

#[panic_handler]
fn panic(info: &PanicInfo<'_>) -> ! {
    // Keep the CPU on the panicking thread. A timer tick could otherwise
    // resume other threads after a kernel invariant broke.
    kernel::cpu::disable_interrupts();
    if PANICKING.swap(true, Ordering::AcqRel) {
        hal::cpu::halt();
    }
    if !HIGHER_HALF.load(Ordering::Acquire) {
        console::print_unsafe("\n[PANIC]\n");
        hal::cpu::halt();
    }

    let mut out = console::Console::new();
    out.print("\n[PANIC]\n");
    let _ = writeln!(out, "{}", info.message());
    if let Some(location) = info.location() {
        let _ = writeln!(
            out,
            "at {}:{}:{}",
            location.file(),
            location.line(),
            location.column()
        );
    }
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

/// Never returns. Runs in the higher half, so a boot failure can panic with
/// its error value.
pub fn kernel_main(info: BootInfo) -> ! {
    HIGHER_HALF.store(true, Ordering::Release);
    let hardware = startup::init::virt_init(info.dtb).expect("boot: virtual init failed");

    kernel::pmm::init(
        &hardware,
        hal::mmu::KERNEL_PHYSICAL_LOAD,
        kernel_physical_end(),
        hal::mmu::physmap_end(),
        hal::mmu::try_physical_to_virtual,
    )
    .expect("pmm: initialization failed");
    startup::log::pmm();
    kernel::allocator::init(
        hal::mmu::try_physical_to_virtual,
        hal::mmu::try_virtual_to_physical,
    );
    kernel::allocator::boot_probe().expect("allocator: boot probe failed");
    let idle_stack = kernel::task::KernelStack::create_mapped(
        hal::mmu::kernel_stack_region_base,
        hal::mmu::map_kernel_stack_page,
        hal::mmu::unmap_kernel_stack_page,
    )
    .expect("task: idle stack allocation failed");
    kernel::task::init_with_idle_thread(idle_stack, idle_thread, 0)
        .expect("task: scheduler initialization failed");
    startup::log::trace();
    hal::interrupt::init(&hardware).expect("interrupt: initialization failed");
    runtime::clock::init().expect("clock: initialization failed");
    hal::timer::enable().expect("clock: timer enable failed");
    runtime::clock::wait_for_first_tick(100_000_000)
        .expect("clock: first timer interrupt did not arrive");
    startup::log::clock();
    startup::log::task();
    startup::log::idle();
    console::Console::new().print("[BOOT:OK]\n");

    enter_idle_thread()
}

fn kernel_physical_end() -> PhysicalAddress {
    let end_virtual = core::ptr::addr_of!(__kernel_end) as usize;
    hal::mmu::try_virtual_to_physical(kernel::mmu::VirtualAddress::new(end_virtual))
        .expect("kernel end is covered by the physmap")
}

fn enter_idle_thread() -> ! {
    kernel::task::enter_idle(switch_context).expect("task: idle context missing");
    panic!("task: idle thread returned")
}

unsafe fn switch_context(old: &mut hal::context::Context, new: &hal::context::Context) {
    // SAFETY: `kernel::task` owns both contexts and checks that the target
    // thread has a live stack before handing control to this architecture call.
    unsafe { hal::context::switch_context(old, new) };
}

extern "C" fn idle_thread(_: usize) -> ! {
    #[cfg(feature = "smoke-test")]
    runtime::smoke::start();
    hal::cpu::halt()
}
