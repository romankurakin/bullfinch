//! ARM64 Interrupt Controller Initialization.
//!
//! The GIC (Generic Interrupt Controller) routes hardware interrupts to CPU cores.
//!
//! See ARM GIC Architecture Specification (IHI 0069) for GICv3,
//! ARM GIC-400 TRM (DDI 0471B) for GICv2.

const fdt = @import("../../fdt/fdt.zig");
const gic = @import("gic.zig");

const panic_msg = struct {
    const GIC_NOT_FOUND = "INTERRUPT: GIC not found in DTB";
};

/// Initialize interrupt controller from DTB configuration.
/// Must be called before timer.start().
pub fn init(dtb: fdt.Fdt) void {
    const gic_info = fdt.getGicInfo(dtb) orelse @panic(panic_msg.GIC_NOT_FOUND);
    gic.init(.{
        .version = gic_info.version,
        .gicd_base = gic_info.gicd_base,
        .gicc_base = gic_info.gicc_base,
        .gicr_base = gic_info.gicr_base,
    });
}
