//! ARM64 interrupt-controller setup.
//!
//! Architecture code translates the neutral `HardwareInfo` snapshot into GICv2
//! or GICv3 register programming. Portable code only asks for interrupt setup
//! and IRQ completion.

use core::arch::asm;
use core::cell::UnsafeCell;
use core::sync::atomic::{AtomicBool, Ordering};

use kernel::{
    hwinfo::{HardwareInfo, InterruptControllerInfo},
    mmu::{PhysicalAddress, VirtualAddress},
};

use super::{cpu, mmio, mmu};

const TIMER_PPI: u32 = 30;
const GIC_SPECIAL_INTERRUPT_START: u32 = 1020;
const GIC_SPECIAL_INTERRUPT_END: u32 = 1023;

// Single writer during boot, many readers from trap context. `GIC_READY` gates
// all reads of `GIC_SLOT`.
//
// TODO(smp): secondary CPUs need a per-CPU GIC view if any field becomes
// CPU-local. Keep the Release/Acquire publication edge for cross-CPU readers.
static GIC_READY: AtomicBool = AtomicBool::new(false);
static GIC_SLOT: GicSlot = GicSlot::empty();

struct GicSlot(UnsafeCell<Option<Gic>>);

// SAFETY: Access is gated by `GIC_READY`. The slot is written exactly once
// during early single-hart boot before `GIC_READY` is set; all later access is
// read-only by value (the `Gic` enum is `Copy`).
unsafe impl Sync for GicSlot {}

impl GicSlot {
    const fn empty() -> Self {
        Self(UnsafeCell::new(None))
    }
}

#[derive(Clone, Copy)]
enum Gic {
    V2(GicV2),
    V3(GicV3),
}

pub fn init(info: &HardwareInfo) {
    let Some(controller) = info.features.interrupt_controller else {
        panic!("gic: missing interrupt controller");
    };

    let gic = match controller {
        InterruptControllerInfo::GicV2 {
            distributor_base,
            cpu_interface_base,
        } => Gic::V2(GicV2::new(
            distributor_base,
            cpu_interface_base.expect("gicv2: missing cpu interface"),
        )),
        InterruptControllerInfo::GicV3 {
            distributor_base,
            redistributor_base,
        } => Gic::V3(GicV3::new(
            distributor_base,
            redistributor_base.expect("gicv3: missing redistributor"),
        )),
    };

    // SAFETY: This is the only writer of `GIC_SLOT`. It runs during single-hart
    // boot with interrupts masked, before any reader can observe
    // `GIC_READY == true`. `gic.init()` owns the controller programming.
    unsafe {
        gic.init();
        *GIC_SLOT.0.get() = Some(gic);
    }
    // Release publishes the `Some(gic)` store to later acquire loads.
    GIC_READY.store(true, Ordering::Release);
}

pub fn enable_timer_interrupt() {
    with_gic(|gic| {
        // SAFETY: MMIO registers programmed here belong to the GIC discovered
        // from the DTB and mapped into the kernel physmap.
        unsafe { gic.enable_timer_interrupt() }
    });
}

pub fn acknowledge() -> Option<u32> {
    let mut intid = None;
    with_gic(|gic| {
        // SAFETY: Read of the GIC IAR register from trap context.
        intid = Some(unsafe { gic.acknowledge() });
    });
    intid
}

pub fn end_of_interrupt(intid: u32) {
    with_gic(|gic| {
        // SAFETY: Writing the previously-acknowledged INTID to EOIR.
        unsafe { gic.end_of_interrupt(intid) };
    });
}

pub fn handle_timer_interrupt(_: Option<kernel::trap::cause::TrapCause>) -> bool {
    let Some(intid) = acknowledge() else {
        return false;
    };
    if is_gic_special_interrupt(intid) {
        return false;
    }
    if intid == TIMER_PPI {
        crate::runtime::clock::handle_timer_irq();
        end_of_interrupt(intid);
        true
    } else {
        end_of_interrupt(intid);
        false
    }
}

fn is_gic_special_interrupt(intid: u32) -> bool {
    // GIC INTIDs 1020-1023 are special values, not active interrupts.
    (GIC_SPECIAL_INTERRUPT_START..=GIC_SPECIAL_INTERRUPT_END).contains(&intid)
}

fn with_gic(f: impl FnOnce(Gic)) {
    if !GIC_READY.load(Ordering::Acquire) {
        return;
    }
    // SAFETY: `GIC_READY` is set only after the single boot-time write of
    // `GIC_SLOT`. The `Gic` enum is `Copy`, so we hand out a value, not a
    // borrow into the cell.
    let gic = unsafe { *GIC_SLOT.0.get() };
    if let Some(gic) = gic {
        f(gic);
    }
}

impl Gic {
    /// # Safety
    /// Caller must own exclusive access to the GIC (true during boot).
    unsafe fn init(self) {
        match self {
            // SAFETY: This method's caller owns the active GIC instance.
            Self::V2(gic) => unsafe { gic.init() },
            // SAFETY: This method's caller owns the active GIC instance.
            Self::V3(gic) => unsafe { gic.init() },
        }
    }

    /// # Safety
    /// Caller must ensure the GIC is initialized.
    unsafe fn enable_timer_interrupt(self) {
        match self {
            // SAFETY: This method's caller proved that the GIC is initialized.
            Self::V2(gic) => unsafe { gic.enable_timer_interrupt() },
            // SAFETY: This method's caller proved that the GIC is initialized.
            Self::V3(gic) => unsafe { gic.enable_timer_interrupt() },
        }
    }

    /// # Safety
    /// Caller must invoke from trap context with the GIC initialized.
    unsafe fn acknowledge(self) -> u32 {
        match self {
            // SAFETY: This method's caller is in trap context with the GIC ready.
            Self::V2(gic) => unsafe { gic.acknowledge() },
            // SAFETY: This method's caller is in trap context with the GIC ready.
            Self::V3(gic) => unsafe { gic.acknowledge() },
        }
    }

    /// # Safety
    /// `intid` must be the value previously returned by `acknowledge`.
    unsafe fn end_of_interrupt(self, intid: u32) {
        match self {
            // SAFETY: This method's caller passes the active INTID.
            Self::V2(gic) => unsafe { gic.end_of_interrupt(intid) },
            // SAFETY: This method's caller passes the active INTID.
            Self::V3(gic) => unsafe { gic.end_of_interrupt(intid) },
        }
    }
}

#[derive(Clone, Copy)]
struct GicV2 {
    distributor: VirtualAddress,
    cpu_interface: VirtualAddress,
}

impl GicV2 {
    const GICC_CONTROL: usize = 0x000;
    const GICC_PRIORITY_MASK: usize = 0x004;
    const GICC_INTERRUPT_ACKNOWLEDGE: usize = 0x00c;
    const GICC_END_OF_INTERRUPT: usize = 0x010;
    const GICD_CONTROL: usize = 0x000;
    const GICD_INTERRUPT_SET_ENABLE: usize = 0x100;
    const GICD_INTERRUPT_PRIORITY: usize = 0x400;

    fn new(distributor: PhysicalAddress, cpu_interface: PhysicalAddress) -> Self {
        Self {
            distributor: mmu::physical_to_virtual(distributor),
            cpu_interface: mmu::physical_to_virtual(cpu_interface),
        }
    }

    /// # Safety
    /// Caller owns the distributor and CPU interface registers.
    unsafe fn init(self) {
        // SAFETY: The caller owns these mapped GICv2 MMIO registers.
        unsafe {
            mmio::write32(self.distributor.checked_add(Self::GICD_CONTROL).unwrap(), 0);
            mmio::write32(self.distributor.checked_add(Self::GICD_CONTROL).unwrap(), 1);
            mmio::write32(
                self.cpu_interface
                    .checked_add(Self::GICC_PRIORITY_MASK)
                    .unwrap(),
                0xff,
            );
            mmio::write32(
                self.cpu_interface.checked_add(Self::GICC_CONTROL).unwrap(),
                1,
            );
        }
    }

    /// # Safety
    /// GIC must be initialized.
    unsafe fn enable_timer_interrupt(self) {
        // SAFETY: The caller proved that the GICv2 distributor is initialized.
        unsafe {
            mmio::write8(
                self.distributor
                    .checked_add(Self::GICD_INTERRUPT_PRIORITY + TIMER_PPI as usize)
                    .unwrap(),
                0x80,
            );
            mmio::write32(
                self.distributor
                    .checked_add(Self::GICD_INTERRUPT_SET_ENABLE)
                    .unwrap(),
                1 << TIMER_PPI,
            );
        }
    }

    /// # Safety
    /// Must be called from trap context with the GIC initialized.
    unsafe fn acknowledge(self) -> u32 {
        // SAFETY: The caller is in trap context and the CPU interface is ready.
        unsafe {
            mmio::read32(
                self.cpu_interface
                    .checked_add(Self::GICC_INTERRUPT_ACKNOWLEDGE)
                    .unwrap(),
            ) & 0x3ff
        }
    }

    /// # Safety
    /// `intid` must be the value previously returned by `acknowledge`.
    unsafe fn end_of_interrupt(self, intid: u32) {
        // SAFETY: The caller passes the INTID returned by this CPU interface.
        unsafe {
            mmio::write32(
                self.cpu_interface
                    .checked_add(Self::GICC_END_OF_INTERRUPT)
                    .unwrap(),
                intid,
            );
        }
        cpu::instruction_barrier();
    }
}

#[derive(Clone, Copy)]
struct GicV3 {
    distributor: VirtualAddress,
    redistributor: VirtualAddress,
}

impl GicV3 {
    const GICD_CONTROL: usize = 0x0000;
    const GICD_CONTROL_ARE_NS: u32 = 1 << 4;
    const GICD_CONTROL_ENABLE_G1NS: u32 = 1 << 1;
    const GICR_SGI_BASE: usize = 0x10000;
    const GICR_WAKER: usize = 0x0014;
    const GICR_IGROUPR0: usize = 0x0080;
    const GICR_INTERRUPT_PRIORITY: usize = 0x0400;
    const GICR_INTERRUPT_SET_ENABLE: usize = 0x0100;
    const GICR_WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;
    const GICR_WAKER_PROCESSOR_SLEEP: u32 = 1 << 1;
    const ICC_SRE_ENABLE_SYSTEM_REGISTERS: u64 = 1 << 0;

    // Bounded redistributor wake handshake. Expiry is treated as a hardware
    // fault instead of spinning forever during boot.
    const WAKE_RETRY_BUDGET: u32 = 1_000_000;

    fn new(distributor: PhysicalAddress, redistributor: PhysicalAddress) -> Self {
        Self {
            distributor: mmu::physical_to_virtual(distributor),
            redistributor: mmu::physical_to_virtual(redistributor),
        }
    }

    /// # Safety
    /// Caller owns the distributor and redistributor registers.
    unsafe fn init(self) {
        enable_gic_system_register_interface();

        // SAFETY: GICv3 distributor lives in MMIO mapped by the kernel physmap.
        unsafe {
            let control = mmio::read32(self.distributor.checked_add(Self::GICD_CONTROL).unwrap());
            mmio::write32(
                self.distributor.checked_add(Self::GICD_CONTROL).unwrap(),
                control | Self::GICD_CONTROL_ARE_NS | Self::GICD_CONTROL_ENABLE_G1NS,
            );
        }
        cpu::data_sync_barrier_system();
        cpu::instruction_barrier();

        // SAFETY: GICR_WAKER belongs to this CPU's redistributor. Clearing
        // PROCESSOR_SLEEP requests wakeup; CHILDREN_ASLEEP falling to 0
        // confirms that register state is usable.
        unsafe {
            let waker = mmio::read32(self.redistributor.checked_add(Self::GICR_WAKER).unwrap());
            mmio::write32(
                self.redistributor.checked_add(Self::GICR_WAKER).unwrap(),
                waker & !Self::GICR_WAKER_PROCESSOR_SLEEP,
            );
            let mut awake = false;
            for _ in 0..Self::WAKE_RETRY_BUDGET {
                if mmio::read32(self.redistributor.checked_add(Self::GICR_WAKER).unwrap())
                    & Self::GICR_WAKER_CHILDREN_ASLEEP
                    == 0
                {
                    awake = true;
                    break;
                }
                core::hint::spin_loop();
            }
            if !awake {
                panic!("gicv3: redistributor wake timeout");
            }
        }

        // SAFETY: ICC_* system registers are the local GICv3 CPU interface.
        // PMR=0xff accepts all priorities. IGRPEN1 enables group 1 interrupts.
        // No `nomem`: enabling interrupts has memory-visible side effects via
        // any handler that runs after this point.
        unsafe {
            asm!(
                "msr icc_pmr_el1, {priority}",
                "msr icc_igrpen1_el1, {enable}",
                priority = in(reg) 0xffu64,
                enable = in(reg) 1u64,
                options(nostack, preserves_flags)
            );
        }
        cpu::instruction_barrier();
        cpu::data_sync_barrier_system();
    }

    /// # Safety
    /// GIC must be initialized.
    unsafe fn enable_timer_interrupt(self) {
        let sgi = self.redistributor.checked_add(Self::GICR_SGI_BASE).unwrap();
        // SAFETY: Programming SGI/PPI bank of the redistributor for the
        // architectural timer PPI.
        unsafe {
            let group = mmio::read32(sgi.checked_add(Self::GICR_IGROUPR0).unwrap());
            mmio::write32(
                sgi.checked_add(Self::GICR_IGROUPR0).unwrap(),
                group | (1 << TIMER_PPI),
            );
            mmio::write8(
                sgi.checked_add(Self::GICR_INTERRUPT_PRIORITY + TIMER_PPI as usize)
                    .unwrap(),
                0x80,
            );
            mmio::write32(
                sgi.checked_add(Self::GICR_INTERRUPT_SET_ENABLE).unwrap(),
                1 << TIMER_PPI,
            );
        }
        cpu::instruction_barrier();
    }

    /// # Safety
    /// Must be called from trap context with the GIC initialized.
    unsafe fn acknowledge(self) -> u32 {
        let intid: u32;
        // SAFETY: ICC_IAR1_EL1 acknowledges the active group 1 interrupt and
        // returns its INTID. Dropping `nomem`: acknowledging is a side effect
        // visible to other CPUs/handlers.
        unsafe {
            asm!("mrs {intid:x}, icc_iar1_el1", intid = out(reg) intid, options(nostack, preserves_flags));
        }
        intid
    }

    /// # Safety
    /// `intid` must be the value previously returned by `acknowledge`.
    unsafe fn end_of_interrupt(self, intid: u32) {
        // SAFETY: Writing the INTID returned by ICC_IAR1_EL1 completes that
        // interrupt at the local GIC CPU interface.
        unsafe {
            asm!("msr icc_eoir1_el1, {intid}", intid = in(reg) u64::from(intid), options(nostack, preserves_flags));
        }
        cpu::instruction_barrier();
    }
}

fn enable_gic_system_register_interface() {
    let sre = read_gic_system_register_enable() | GicV3::ICC_SRE_ENABLE_SYSTEM_REGISTERS;
    write_gic_system_register_enable(sre);
    cpu::instruction_barrier();
}

fn read_gic_system_register_enable() -> u64 {
    let value: u64;
    // SAFETY: Reading ICC_SRE_EL1 inspects the local GIC CPU-interface mode.
    unsafe {
        asm!("mrs {value}, icc_sre_el1", value = out(reg) value, options(nomem, nostack, preserves_flags));
    }
    value
}

fn write_gic_system_register_enable(value: u64) {
    // SAFETY: ICC_SRE_EL1.SRE selects the GIC system-register CPU interface.
    // Higher exception levels must already allow EL1 access. Later ICC_* access
    // would trap otherwise.
    unsafe {
        asm!(
            "msr icc_sre_el1, {value}",
            value = in(reg) value,
            options(nostack, preserves_flags)
        );
    }
}
