//! Trap Module.
//!
//! Trap handling infrastructure: frame layout, classification, and result types.
//! Architecture-specific entry points live in arch/{arm64,riscv64}/trap.zig.

pub const fmt = @import("fmt.zig");
pub const dispatch = @import("dispatch.zig");
pub const result = @import("result.zig");
pub const trap_frame = @import("trap_frame.zig");

pub const TrapFrame = trap_frame.TrapFrame;
pub const TrapKind = dispatch.TrapKind;
pub const TrapInfo = dispatch.TrapInfo;
pub const TrapResult = result.TrapResult;
pub const classify = dispatch.classify;
pub const kindName = dispatch.kindName;

comptime {
    _ = fmt;
    _ = dispatch;
    _ = result;
    _ = trap_frame;
}
