//! Task Subsystem.
//!
//! Provides thread, process, and scheduler abstractions for multitasking.
//! Threads are the unit of scheduling; processes are resource containers.
//!
//! Initialize with init() after PMM and allocator are ready.
//! The scheduler creates an idle thread and kernel process during init.

const memory = @import("../memory/memory.zig");

/// Must hold trap frames and call chains.
pub const KERNEL_STACK_SIZE: usize = memory.PAGE_SIZE * 2;

// CFS-style weight: higher = more CPU time.
pub const SCHED_BASE_WEIGHT: u32 = 1024; // nice 0
pub const SCHED_MIN_WEIGHT: u32 = 1; // idle

pub const SCHED_TIME_SLICE_NS: u64 = 10_000_000; // 10ms

pub const process = @import("process.zig");
pub const scheduler = @import("scheduler.zig");
pub const stack = @import("stack.zig");
pub const thread = @import("thread.zig");

pub const Process = process.Process;
pub const ProcessId = process.ProcessId;
pub const Stack = stack.Stack;
pub const Thread = thread.Thread;
pub const ThreadId = thread.ThreadId;

pub fn init() void {
    stack.init();
    scheduler.init();
}

comptime {
    // Force inclusion of all submodules for testing
    _ = process;
    _ = scheduler;
    _ = stack;
    _ = thread;
}
