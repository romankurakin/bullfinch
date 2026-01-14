//! ARM64 CPU primitives for synchronization.
//!
//! Uses exclusive monitor mechanism: load-exclusive sets monitor, store-release
//! clears it (waking WFE waiters). See ARM Architecture Reference Manual,
//! B2.12 (Synchronization and Semaphores) and D1.7 (Low-power State).
//!
//! ## Zig Inline Assembly Limitation
//!
//! ARM64 has 32-bit (W) and 64-bit (X) register forms. Instructions like
//! `stlr w1, [x0]` require the W form for 32-bit atomics. Zig's inline asm
//! always allocates X registers and lacks modifiers to request W form.
//!
//! Workaround: Use `comptime { asm(...) }` to define global assembly functions
//! with explicit register names, then declare them as `extern fn`.

comptime {
    asm (
        \\.global storeRelease32
        \\storeRelease32:
        \\    stlr w1, [x0]
        \\    ret
        \\
        \\.global loadAcquireExclusive32
        \\loadAcquireExclusive32:
        \\    ldaxr w0, [x0]
        \\    ret
    );
}

/// 32-bit store with release semantics (STLR). Clears exclusive monitor.
extern fn storeRelease32(ptr: *u32, val: u32) void;

/// 32-bit load with acquire semantics (LDAXR). Sets exclusive monitor.
extern fn loadAcquireExclusive32(ptr: *const u32) u32;

/// Spin until 32-bit value at `ptr` equals `expected`.
/// Uses WFE for low-power waiting; wakes when exclusive monitor clears.
pub fn spinWaitEq(ptr: *const u32, expected: u32) void {
    asm volatile ("sevl"); // Prevent missed wake before first WFE.
    while (loadAcquireExclusive32(ptr) != expected) {
        asm volatile ("wfe");
    }
}

/// Store with release semantics. Clears exclusive monitor to wake WFE waiters.
pub const storeRelease = storeRelease32;
