//! Trap Handling Infrastructure.
//!
//! Provides architecture-independent trap frame access, formatting utilities,
//! and backtrace support. Architecture-specific entry points and vector tables
//! live in arch/.

const hal = @import("../hal/hal.zig");

pub const backtrace = @import("backtrace.zig");
pub const fmt = @import("fmt.zig");

pub const TrapFrame = hal.trap_frame.TrapFrame;
pub const readStackFrame = hal.trap_frame.readStackFrame;

comptime {
    _ = backtrace;
    _ = fmt;
}
