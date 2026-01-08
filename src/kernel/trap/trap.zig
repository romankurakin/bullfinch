//! Trap Module.
//!
//! Re-exports trap-related submodules.

pub const fmt = @import("fmt.zig");

comptime {
    _ = fmt;
}
