//! ARM64 Interrupt Controller Initialization.
//!
//! The GIC (Generic Interrupt Controller) routes hardware interrupts to CPU cores.
//!
//! See ARM GIC Architecture Specification (IHI 0069) for GICv3,
//! ARM GIC-400 TRM (DDI 0471B) for GICv2.

const gic = @import("gic.zig");
const hwinfo = @import("../../hwinfo/hwinfo.zig");

const panic_msg = struct {
    const GIC_NOT_FOUND = "gic: not found in hardware info";
};

/// Initialize interrupt controller from hardware info.
/// Must be called before timer.start().
pub fn init() void {
    const gic_info = hwinfo.info.features.arm64.gic;
    if (gic_info.version == 0) @panic(panic_msg.GIC_NOT_FOUND);
    gic.init(.{
        .version = gic_info.version,
        .gicd_base = gic_info.gicd_base,
        .gicc_base = gic_info.gicc_base,
        .gicr_base = gic_info.gicr_base,
    });
}
