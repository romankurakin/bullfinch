//! Hardware abstraction layer.
//!
//! Portable code should use this module instead of reaching into `arch`
//! directly. It provides thin wrappers that forward to the selected
//! architecture implementation at compile time with zero runtime cost.

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
    /// The scheduler must hold exclusive ownership of both contexts and must
    /// only switch to a context with a live kernel stack and valid return
    /// address.
    pub unsafe fn switch_context(old: &mut Context, new: &Context) {
        // SAFETY: This is the HAL boundary for the arch-specific switch ABI.
        unsafe { kernel::context::switch_context(old, new) };
    }

    /// Switches context from a trap or IRQ handler without changing live IRQ state.
    ///
    /// # Safety
    ///
    /// The caller must be returning through an architecture exception return
    /// frame that will restore interrupt state.
    pub unsafe fn switch_context_from_trap(old: &mut Context, new: &Context) {
        // SAFETY: This is the HAL boundary for the arch-specific trap switch ABI.
        unsafe { kernel::context::switch_context_from_trap(old, new) };
    }
}

pub mod interrupt {
    use kernel::hwinfo::HardwareInfo;
    use kernel::trap::cause::TrapCause;

    pub fn init(info: &HardwareInfo) {
        crate::arch::interrupt::init(info);
    }

    pub fn handle_timer_interrupt(cause: Option<TrapCause>) -> bool {
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

    pub fn physical_to_virtual(address: PhysicalAddress) -> VirtualAddress {
        crate::arch::mmu::physical_to_virtual(address)
    }

    pub fn virtual_to_physical(address: VirtualAddress) -> PhysicalAddress {
        crate::arch::mmu::virtual_to_physical(address)
    }

    pub fn init(dtb: DeviceTreeBlobPhysicalAddress) {
        crate::arch::mmu::init(KERNEL_PHYSICAL_LOAD, dtb);
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
        let physical = page.leak_physical()?;
        let virtual_address = physical_to_virtual(physical);
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
