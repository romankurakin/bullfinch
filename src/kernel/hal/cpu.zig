//! CPU Primitives Hardware Abstraction.
//!
//! ARM64 uses LDAXR+WFE for low-power sleep; RISC-V polls with pause hints.

const builtin = @import("builtin");
const std = @import("std");

const is_kernel_target = builtin.os.tag == .freestanding and
    (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .riscv64);

const arch_cpu = if (is_kernel_target)
    switch (builtin.cpu.arch) {
        .aarch64 => @import("../arch/arm64/cpu.zig"),
        .riscv64 => @import("../arch/riscv64/cpu.zig"),
        else => unreachable,
    }
else
    // Host fallback for tests.
    struct {
        pub fn spinWaitEq(ptr: *const u32, expected: u32) void {
            const atomic_ptr: *const std.atomic.Value(u32) = @ptrCast(ptr);
            while (atomic_ptr.load(.acquire) != expected) {
                std.atomic.spinLoopHint();
            }
        }

        pub fn storeRelease(ptr: *u32, val: u32) void {
            const atomic_ptr: *std.atomic.Value(u32) = @ptrCast(ptr);
            atomic_ptr.store(val, .release);
        }
    };

/// Spin until 32-bit value at `ptr` equals `expected`.
pub const spinWaitEq = arch_cpu.spinWaitEq;

/// Store with release semantics. On ARM64, uses STLR to wake WFE waiters.
pub const storeRelease = arch_cpu.storeRelease;
