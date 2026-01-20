//! GIC (Generic Interrupt Controller) Dispatcher.
//!
//! ARM systems use the GIC to route hardware interrupts to CPU cores. GICv2 uses
//! memory-mapped registers for everything, while GICv3 moves the CPU interface to
//! system registers for lower latency.
//!
//! This module discovers the GIC version from DTB and dispatches to the appropriate
//! implementation at runtime.

const gicv2 = @import("gicv2.zig");
const gicv3 = @import("gicv3.zig");

const panic_msg = struct {
    const NOT_INITIALIZED = "gic: not initialized";
    const UNSUPPORTED_VERSION = "gic: unsupported version";
};

/// EL1 physical timer PPI interrupt ID.
/// PPIs 16-31 are private to each core. CNTP (physical timer) is architecturally PPI 30.
pub const TIMER_PPI: u32 = 30;

/// GIC configuration discovered from DTB.
pub const GicInfo = struct {
    version: u8,
    gicd_base: u64,
    gicc_base: u64, // GICv2 only
    gicr_base: u64, // GICv3 only
};

var gic_version: u8 = 0;

/// Initialize GIC with info discovered from DTB.
pub fn init(info: GicInfo) void {
    gic_version = info.version;
    switch (info.version) {
        2 => gicv2.init(info.gicd_base, info.gicc_base),
        3 => gicv3.init(info.gicd_base, info.gicr_base),
        else => @panic(panic_msg.UNSUPPORTED_VERSION),
    }
}

/// Enable the EL1 physical timer interrupt (PPI 30).
pub fn enableTimerInterrupt() void {
    switch (gic_version) {
        2 => gicv2.enableTimerInterrupt(),
        3 => gicv3.enableTimerInterrupt(),
        else => @panic(panic_msg.NOT_INITIALIZED),
    }
}

/// Acknowledge current interrupt and return its ID. Returns 1023 for spurious.
pub inline fn acknowledge() u32 {
    return switch (gic_version) {
        2 => gicv2.acknowledge(),
        3 => gicv3.acknowledge(),
        else => 1023, // Spurious
    };
}

/// Signal end of interrupt handling to GIC.
pub inline fn endOfInterrupt(intid: u32) void {
    switch (gic_version) {
        2 => gicv2.endOfInterrupt(intid),
        3 => gicv3.endOfInterrupt(intid),
        else => {},
    }
}
