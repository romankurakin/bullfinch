//! Test-only board shim for native unit tests.
//!
//! Host tests exercise portable code paths and a few arch-specific helpers, but
//! they do not boot a real kernel image. Provide minimal board constants so
//! modules importing `@import("board")` compile under `zig test`.

/// Arbitrary page-aligned load address for compile-time checks.
pub const KERNEL_PHYS_LOAD: usize = 0x4000_0000;

/// Dummy UART base used only by unit tests that never touch hardware.
pub const UART_PHYS: usize = 0x0900_0000;

pub fn kernelEnd() usize {
    return KERNEL_PHYS_LOAD + 0x20_0000;
}
