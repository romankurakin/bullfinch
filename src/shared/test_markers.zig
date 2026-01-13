//! Test markers for kernel output.
//!
//! Used by both the kernel and the smoke test harness (tests/smoke.zig).
//! Single source of truth for test detection strings.

/// Printed when boot completes successfully.
pub const BOOT_OK = "[BOOT:OK]";

/// Printed on kernel panic.
pub const PANIC = "[PANIC]";
