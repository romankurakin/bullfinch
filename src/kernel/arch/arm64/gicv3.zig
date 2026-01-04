//! GICv3 Interrupt Controller.
//!
//! GICv3 is the modern ARM interrupt controller. It has three main components:
//!
//!   GICD (Distributor) - Shared across all cores. Routes SPIs (Shared Peripheral
//!   Interrupts) from devices to specific cores based on affinity.
//!
//!   GICR (Redistributor) - One per core. Handles PPIs (Private Peripheral Interrupts)
//!   like timers, and SGIs (Software Generated Interrupts) for IPIs.
//!
//!   ICC_* system registers - The CPU interface.
//!
//! Our timer (CNTP) generates PPI 30. PPIs are configured per-core in the GICR.
//!
//! See ARM GIC Architecture Specification, Chapter 12 (GIC Programmer's Model).

const board = @import("board");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");

const GICD_CTLR: usize = 0x0000;
const GICD_CTLR_ARE_NS: u32 = 1 << 4;
const GICD_CTLR_ENABLE_G1NS: u32 = 1 << 1;

const GICR_SGI_BASE: usize = 0x10000;
const GICR_WAKER: usize = 0x0014;
const GICR_IGROUPR0: usize = 0x0080;
const GICR_IPRIORITYR: usize = 0x0400;
const GICR_ISENABLER0: usize = 0x0100;
const GICR_WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;
const GICR_WAKER_PROCESSOR_SLEEP: u32 = 1 << 1;

const TIMER_PPI: u32 = 30;

var gicd_base: usize = 0;
var gicr_base: usize = 0;

/// Initialize GICv3 distributor and redistributor.
pub fn init() void {
    gicd_base = mmu.physToVirt(board.config.GICD_BASE);
    gicr_base = mmu.physToVirt(board.config.GICR_BASE);

    const ctlr = mmio.read32(gicd_base + GICD_CTLR);
    mmio.write32(gicd_base + GICD_CTLR, ctlr | GICD_CTLR_ARE_NS | GICD_CTLR_ENABLE_G1NS);

    const waker = mmio.read32(gicr_base + GICR_WAKER);
    mmio.write32(gicr_base + GICR_WAKER, waker & ~GICR_WAKER_PROCESSOR_SLEEP);
    while (mmio.read32(gicr_base + GICR_WAKER) & GICR_WAKER_CHILDREN_ASLEEP != 0) {}

    asm volatile ("msr icc_pmr_el1, %[pmr]"
        :
        : [pmr] "r" (@as(u64, 0xFF)),
    );
    asm volatile ("msr icc_igrpen1_el1, %[en]"
        :
        : [en] "r" (@as(u64, 1)),
    );
    asm volatile ("isb");
}

/// Enable the timer PPI (INTID 30).
pub fn enableTimerInterrupt() void {
    const sgi_base = gicr_base + GICR_SGI_BASE;

    const group = mmio.read32(sgi_base + GICR_IGROUPR0);
    mmio.write32(sgi_base + GICR_IGROUPR0, group | (@as(u32, 1) << TIMER_PPI));
    mmio.write8(sgi_base + GICR_IPRIORITYR + TIMER_PPI, 0x80);
    mmio.write32(sgi_base + GICR_ISENABLER0, @as(u32, 1) << TIMER_PPI);

    asm volatile ("isb");
}

/// Acknowledge interrupt - read IAR to get INTID.
/// Must be called at start of IRQ handler.
pub inline fn acknowledge() u32 {
    return asm volatile ("mrs %[iar], icc_iar1_el1"
        : [iar] "=r" (-> u32),
    );
}

/// End of interrupt - signal completion to GIC.
/// Must be called at end of IRQ handler with the INTID from acknowledge().
pub inline fn endOfInterrupt(intid: u32) void {
    asm volatile ("msr icc_eoir1_el1, %[eoir]"
        :
        : [eoir] "r" (@as(u64, intid)),
    );
}

