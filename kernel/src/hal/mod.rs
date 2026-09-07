//! Hardware abstraction layer.
//!
//! Portable code should call this module for architecture operations. Its
//! wrappers select the architecture implementation at compile time, without
//! a runtime architecture check.

pub mod cpu {
    pub fn halt() -> ! {
        crate::arch::cpu::halt()
    }
}

pub mod context {
    pub type Context = kernel::context::Context;

    /// Switches from one kernel context to another.
    ///
    /// # Safety
    ///
    /// The scheduler must hold exclusive ownership of both contexts. The target
    /// context must have a live kernel stack and a valid return address.
    pub unsafe fn switch_context(old: &mut Context, new: &Context) {
        // SAFETY: This is the HAL boundary for the arch-specific switch ABI.
        unsafe { kernel::context::switch_context(old, new) };
    }

    /// Switches context from a trap or IRQ handler without changing live IRQ state.
    ///
    /// # Safety
    ///
    /// The caller must be on a trap path. The incoming context must resume
    /// through an exception frame or start at the thread trampoline, which
    /// enables interrupts on first entry.
    pub unsafe fn switch_context_from_trap(old: &mut Context, new: &Context) {
        // SAFETY: This is the HAL boundary for the arch-specific trap switch ABI.
        unsafe { kernel::context::switch_context_from_trap(old, new) };
    }
}

pub mod fp {
    use kernel::fp::ThreadFpState;

    /// Transfers the resident user FP register file between scheduler threads.
    ///
    /// # Safety
    ///
    /// Trap entry must have disabled kernel FP access.
    /// `old` must describe the interrupted thread.
    /// `new` must describe the thread selected to run.
    pub unsafe fn context_switch(old: &mut ThreadFpState, new: &ThreadFpState) {
        // SAFETY: This is the HAL boundary for the architecture FP ownership
        // transfer. The caller upholds its trap and scheduler requirements.
        unsafe { crate::arch::fp::context_switch(old, new) };
    }
}

pub mod interrupt {
    use kernel::hwinfo::HardwareInfo;
    use kernel::trap::{cause::TrapCause, dispatch::InterruptAction};

    pub type InitError = crate::arch::interrupt::InitError;

    pub fn init(info: &HardwareInfo) -> Result<(), InitError> {
        crate::arch::interrupt::init(info)
    }

    pub fn handle_timer_interrupt(cause: Option<TrapCause>) -> InterruptAction {
        crate::arch::interrupt::handle_timer_interrupt(cause)
    }
}

pub mod mmu {
    use kernel::{
        boot::DeviceTreeBlobPhysicalAddress,
        hwinfo::HardwareInfo,
        mmu::{
            MapError, MappingPermissions, PAGE_SIZE, PhysicalAddress, UnmapError, VirtualAddress,
        },
        pmm,
    };

    pub const KERNEL_PHYSICAL_LOAD: PhysicalAddress =
        PhysicalAddress::new(crate::arch::mmu::KERNEL_PHYSICAL_LOAD);

    pub fn try_physical_to_virtual(address: PhysicalAddress) -> Option<VirtualAddress> {
        crate::arch::mmu::try_physical_to_virtual(address)
    }

    pub fn try_virtual_to_physical(address: VirtualAddress) -> Option<PhysicalAddress> {
        crate::arch::mmu::try_virtual_to_physical(address)
    }

    pub fn init(dtb: DeviceTreeBlobPhysicalAddress) -> Result<(), MapError> {
        crate::arch::mmu::init(KERNEL_PHYSICAL_LOAD, dtb)
    }

    pub fn post_mmu_init() {
        crate::arch::mmu::post_mmu_init();
    }

    pub fn expand_physmap(info: &HardwareInfo) {
        crate::arch::mmu::expand_physmap(info.max_memory_end());
    }

    pub fn kernel_stack_region_base() -> VirtualAddress {
        crate::arch::mmu::kernel_stack_region_base()
    }

    pub fn map_kernel_stack_page(
        virtual_address: VirtualAddress,
        physical_address: PhysicalAddress,
    ) -> Result<(), MapError> {
        crate::arch::mmu::map_kernel_page_with_alloc(
            virtual_address,
            physical_address,
            MappingPermissions::KERNEL_READ_WRITE,
            allocate_page_table,
        )
    }

    pub fn unmap_kernel_stack_page(
        virtual_address: VirtualAddress,
    ) -> Result<PhysicalAddress, UnmapError> {
        crate::arch::mmu::unmap_kernel_page(virtual_address)
    }

    fn allocate_page_table() -> Option<VirtualAddress> {
        let page = pmm::alloc_page()?;
        let physical = page.physical_address()?;
        let virtual_address = try_physical_to_virtual(physical)?;
        let transferred = page.into_physical();
        // The transfer must preserve the page identity checked before mapper lookup.
        debug_assert_eq!(transferred, physical);
        // SAFETY: PMM just gave this page to the page-table allocator. The
        // physmap covers PMM pages, and no other owner can observe initialized
        // table entries until the caller installs the descriptor.
        unsafe { core::ptr::write_bytes(virtual_address.get() as *mut u8, 0, PAGE_SIZE) };
        Some(virtual_address)
    }

    pub fn remove_identity_mapping() {
        crate::arch::mmu::remove_identity_mapping();
    }
}

pub mod timer {
    use kernel::{
        hwinfo::HardwareInfo,
        time::{Deadline, Frequency, Ticks, TimerError},
    };

    pub fn init_frequency(info: &HardwareInfo) {
        crate::arch::timer::init_frequency(info.timer_frequency);
    }

    pub fn frequency() -> Option<Frequency> {
        crate::arch::timer::frequency()
    }

    pub fn now() -> Ticks {
        crate::arch::timer::now()
    }

    pub fn set_deadline(deadline: Deadline) -> Result<(), TimerError> {
        crate::arch::timer::set_deadline(deadline)
    }

    pub fn enable() -> Result<(), TimerError> {
        crate::arch::timer::enable()
    }
}

pub mod trap {
    pub fn init() {
        crate::arch::trap::init();
    }
}
