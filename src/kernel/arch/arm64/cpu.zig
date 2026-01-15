//! ARM64 CPU primitives for synchronization.
//!
//! Uses exclusive monitor mechanism: LDAXR sets monitor, any store clears it
//! (waking WFE waiters).
//!
//! See ARM Architecture Reference Manual, B2.12 (Synchronization and Semaphores).

/// Spin until low 16 bits of value at `ptr` equals `expected`.
pub fn spinWaitEq16(ptr: *const u32, expected: u16) void {
    asm volatile ("sevl");
    while (true) {
        // Load 32-bit with exclusive monitor, then truncate to 16-bit.
        // LDAXRH requires W register which Zig doesn't support directly.
        const val: u16 = @truncate(asm volatile ("ldaxr %[val], [%[ptr]]"
            : [val] "=&r" (-> u32),
            : [ptr] "r" (ptr),
            : .{ .memory = true }
        ));
        if (val == expected) break;
        asm volatile ("wfe");
    }
}
