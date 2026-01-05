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

pub const GicInfo = struct {
    version: u8,
    gicd_base: u64,
    gicc_base: u64,
    gicr_base: u64,
};

var gic_version: u8 = 0;

/// Initialize GIC with info discovered from DTB.
pub fn init(info: GicInfo) void {
    gic_version = info.version;
    switch (info.version) {
        2 => gicv2.init(info.gicd_base, info.gicc_base),
        3 => gicv3.init(info.gicd_base, info.gicr_base),
        else => @panic("Unsupported GIC version"),
    }
}

pub fn enableTimerInterrupt() void {
    switch (gic_version) {
        2 => gicv2.enableTimerInterrupt(),
        3 => gicv3.enableTimerInterrupt(),
        else => @panic("GIC not initialized"),
    }
}

pub inline fn acknowledge() u32 {
    return switch (gic_version) {
        2 => gicv2.acknowledge(),
        3 => gicv3.acknowledge(),
        else => 1023, // Spurious
    };
}

pub inline fn endOfInterrupt(intid: u32) void {
    switch (gic_version) {
        2 => gicv2.endOfInterrupt(intid),
        3 => gicv3.endOfInterrupt(intid),
        else => {},
    }
}
