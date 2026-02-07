//! GICv3 Interrupt Controller.
//!
//! GICv3 is the modern ARM interrupt controller. It has three main components:
//! - GICD (Distributor): Shared across all cores. Routes SPIs from devices to cores.
//! - GICR (Redistributor): One per core. Handles PPIs (like timers) and SGIs (for IPIs).
//! - ICC_* system registers: The CPU interface.
//!
//! Our timer (CNTP) generates PPI 30. PPIs are configured per-core in the GICR.
//!
//! See ARM GIC Architecture Specification, Chapter 12 (GIC Programmer's Model).

const std = @import("std");
const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");

const TIMER_PPI = gic.TIMER_PPI;

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
const GICR_WAKE_RETRIES: usize = 1000;

const panic_msg = struct {
    const REDISTRIBUTOR_WAKE_TIMEOUT = "gicv3: redistributor wake timeout";
};

var gicd_base: usize = 0;
var gicr_base: usize = 0;

/// Initialize GICv3 distributor and redistributor.
pub fn init(gicd_phys: u64, gicr_phys: u64) void {
    gicd_base = mmu.physToVirt(@intCast(gicd_phys));
    gicr_base = mmu.physToVirt(@intCast(gicr_phys));

    const ctlr = mmio.read32(gicd_base + GICD_CTLR);
    mmio.write32(gicd_base + GICD_CTLR, ctlr | GICD_CTLR_ARE_NS | GICD_CTLR_ENABLE_G1NS);
    // Ensure Distributor enable is globally visible before CPU-interface sysreg programming.
    cpu.dataSyncBarrierSy();
    cpu.instructionBarrier();

    // Wake redistributor - clear PROCESSOR_SLEEP and wait for CHILDREN_ASLEEP to clear.
    // Per GIC spec, this completes within a few cycles once sleep is cleared.
    // On real hardware this is near-instant; QEMU completes it synchronously.
    const waker = mmio.read32(gicr_base + GICR_WAKER);
    mmio.write32(gicr_base + GICR_WAKER, waker & ~GICR_WAKER_PROCESSOR_SLEEP);
    var retries = GICR_WAKE_RETRIES;
    while (mmio.read32(gicr_base + GICR_WAKER) & GICR_WAKER_CHILDREN_ASLEEP != 0) {
        if (retries == 0) @panic(panic_msg.REDISTRIBUTOR_WAKE_TIMEOUT);
        retries -= 1;
        std.atomic.spinLoopHint();
    }

    asm volatile ("msr icc_pmr_el1, %[pmr]"
        :
        : [pmr] "r" (@as(u64, 0xFF)),
    );
    asm volatile ("msr icc_igrpen1_el1, %[en]"
        :
        : [en] "r" (@as(u64, 1)),
    );
    cpu.instructionBarrier();
    // Ensure CPU-interface system register writes are visible to the redistributor.
    cpu.dataSyncBarrierSy();
}

/// Enable the timer PPI (INTID 30).
pub fn enableTimerInterrupt() void {
    const sgi_base = gicr_base + GICR_SGI_BASE;

    const group = mmio.read32(sgi_base + GICR_IGROUPR0);
    mmio.write32(sgi_base + GICR_IGROUPR0, group | (@as(u32, 1) << TIMER_PPI));
    mmio.write8(sgi_base + GICR_IPRIORITYR + TIMER_PPI, 0x80);
    mmio.write32(sgi_base + GICR_ISENABLER0, @as(u32, 1) << TIMER_PPI);

    cpu.instructionBarrier();
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
    cpu.instructionBarrier();
}
