//! GICv2 Interrupt Controller.
//!
//! GICv2 (used in GIC-400 on Raspberry Pi 5) is the older ARM interrupt controller.
//! Unlike GICv3, everything is memory-mapped including the CPU interface.
//! - GICD (Distributor): Shared, routes interrupts to CPU interfaces.
//! - GICC (CPU Interface): Per-CPU, memory-mapped registers for ack/EOI.
//!
//! Timer interrupt (CNTP) is PPI 30. PPIs 16-31 are in ISENABLER0.
//!
//! See ARM GIC-400 Technical Reference Manual.

const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const mmio = @import("mmio.zig");
const mmu = @import("mmu.zig");

const TIMER_PPI = gic.TIMER_PPI;

const GICC_CTLR: usize = 0x000;
const GICC_EOIR: usize = 0x010;
const GICC_IAR: usize = 0x00C;
const GICC_PMR: usize = 0x004;

const GICD_CTLR: usize = 0x000;
const GICD_IPRIORITYR: usize = 0x400;
const GICD_ISENABLER: usize = 0x100;

var gicd_base: usize = 0;
var gicc_base: usize = 0;

/// Initialize GICv2 distributor and CPU interface.
pub fn init(gicd_phys: u64, gicc_phys: u64) void {
    gicd_base = mmu.physToVirt(@intCast(gicd_phys));
    gicc_base = mmu.physToVirt(@intCast(gicc_phys));

    mmio.write32(gicd_base + GICD_CTLR, 0);
    mmio.write32(gicd_base + GICD_CTLR, 1);
    mmio.write32(gicc_base + GICC_PMR, 0xFF);
    mmio.write32(gicc_base + GICC_CTLR, 1);
}

/// Enable the timer PPI (INTID 30).
pub fn enableTimerInterrupt() void {
    mmio.write8(gicd_base + GICD_IPRIORITYR + TIMER_PPI, 0x80);
    mmio.write32(gicd_base + GICD_ISENABLER, @as(u32, 1) << TIMER_PPI);
}

/// Acknowledge interrupt - read IAR to get INTID (bits 9:0).
pub inline fn acknowledge() u32 {
    return mmio.read32(gicc_base + GICC_IAR) & 0x3FF;
}

/// End of interrupt - signal completion to GIC.
pub inline fn endOfInterrupt(intid: u32) void {
    mmio.write32(gicc_base + GICC_EOIR, intid);
    cpu.instructionBarrier();
}
