//! Fair Scheduler with Virtual Runtime.
//!
//! Implements a CFS-inspired fair scheduler using virtual runtime (vruntime).
//! Each thread accumulates vruntime proportional to its CPU usage, inversely
//! weighted by its priority. The thread with the lowest vruntime runs next.
//!
//! Key concepts:
//! - vruntime: Weighted execution time. Low vruntime = deserves more CPU.
//! - weight: Thread priority. Higher weight = lower vruntime accumulation.
//! - runqueue: Red-black tree ordered by vruntime. O(1) min, O(log n) insert/remove.
//!
//! See CFS documentation and "A Complete Fair Scheduler" paper.
//!
//! Trace calls are made with scheduler lock held. Trace uses IRQ disable only,
//! never acquires locks, so no deadlock risk.
//!
//! TODO(smp): Per-CPU runqueues and load balancing.
//! TODO(smp): Current thread should be per-CPU variable.
//! TODO(pm): Exited threads leak memory. Cleanup deferred to userspace PM.

const builtin = @import("builtin");
const std = @import("std");

const hal = @import("../hal/hal.zig");
const process = @import("process.zig");
const rbtree = @import("rbtree.zig");
const sync = @import("../sync/sync.zig");
const task = @import("task.zig");
const thread = @import("thread.zig");
const trace = @import("../debug/trace.zig");

const Process = process.Process;
const Thread = thread.Thread;

fn compareVruntime(a: *const Thread, b: *const Thread) rbtree.Order {
    return std.math.order(a.virtual_runtime, b.virtual_runtime);
}

const RunQueue = rbtree.RedBlackTree(Thread, "rb_node", compareVruntime);

const panic_msg = struct {
    const ZERO_WEIGHT = "scheduler: zero weight thread";
    const KERNEL_PROCESS_FAILED = "scheduler: failed to create kernel process";
    const IDLE_THREAD_FAILED = "scheduler: failed to create idle thread";
    const ENTER_IDLE_BEFORE_INIT = "scheduler: enterIdle before init";
    const EXITED_THREAD_SCHEDULED = "scheduler: exited thread was rescheduled";
};

const debug_kernel = builtin.mode == .Debug;

/// Idle threads stay off the runqueue; pickNextAndDequeue falls back to idle when empty.
inline fn isIdle(t: *const Thread) bool {
    return if (idle_thread) |idle| t == idle else false;
}

// Scheduler state protected by lock.
var runqueue: RunQueue = .{};
var current_thread: ?*Thread = null;
var idle_thread: ?*Thread = null;
var kernel_process: *Process = undefined;
var boot_context: hal.context.Context = .{};
var min_vruntime: u64 = 0;
export var need_resched: bool = false;

/// TODO(smp): Fine-grained locking or per-CPU runqueues.
var lock: sync.SpinLock = .{};

/// Initialize scheduler, kernel process, and idle thread.
pub fn init() void {
    process.init();
    thread.init(&exit);

    kernel_process = process.create() orelse {
        @panic(panic_msg.KERNEL_PROCESS_FAILED);
    };

    idle_thread = thread.createIdleThread(kernel_process) orelse {
        @panic(panic_msg.IDLE_THREAD_FAILED);
    };

    const idle = idle_thread.?;
    idle.virtual_runtime = 0;
    idle.state = .ready;

    // Running on boot stack, not a real thread context yet.
    // setKernelStack not called: ARM64 SP_EL1 is live (would corrupt stack),
    // RISC-V sscratch safe but unneeded for kernel-only operation.
    current_thread = idle;
    idle.state = .running;
}

/// Add thread to runqueue.
pub fn enqueue(t: *Thread) void {
    const held = lock.guard();
    defer held.release();

    enqueueLocked(t);
    if (comptime trace.debug_kernel) trace.emit(.sched_enqueue, t.id, t.virtual_runtime, @intFromEnum(t.state));
}

inline fn enqueueLocked(t: *Thread) void {
    if (isIdle(t)) {
        t.state = .ready;
        return;
    }

    // New threads start at min_vruntime for fairness.
    if (t.virtual_runtime < min_vruntime) {
        t.virtual_runtime = min_vruntime;
    }

    runqueue.insert(&t.rb_node);
    t.state = .ready;
}

inline fn dequeueLocked(t: *Thread) void {
    if (!t.rb_node.isLinked()) return;
    runqueue.remove(&t.rb_node);
    if (comptime trace.debug_kernel) trace.emit(.sched_dequeue, t.id, t.virtual_runtime, @intFromEnum(t.state));
}

inline fn pickNextAndDequeue() *Thread {
    const idle = idle_thread.?;
    const min_node = runqueue.extractMin() orelse return idle;
    const best = RunQueue.entry(min_node);
    if (comptime trace.debug_kernel) trace.emit(.sched_dequeue, best.id, best.virtual_runtime, @intFromEnum(best.state));
    return best;
}

/// Return currently running thread.
pub fn current() ?*Thread {
    return current_thread;
}

/// Timer tick. Updates vruntime and sets need_resched if preemption needed.
pub fn tick() void {
    const held = lock.guard();
    defer held.release();

    const curr = current_thread orelse return;
    if (curr.weight == 0) @panic(panic_msg.ZERO_WEIGHT);

    // vruntime delta inversely proportional to weight (higher weight = more CPU time).
    const elapsed_ns = task.SCHED_TIME_SLICE_NS;
    const delta = elapsed_ns * @as(u64, task.SCHED_BASE_WEIGHT) / @as(u64, curr.weight);
    curr.virtual_runtime +|= delta;
    if (comptime trace.debug_kernel) trace.emit(.sched_tick, curr.id, curr.virtual_runtime, 0);

    // O(1) check: tree's cached min vs current thread.
    // Also update min_vruntime in same pass to avoid double tree access.
    if (runqueue.min()) |min_node| {
        const best = RunQueue.entry(min_node);
        if (best.virtual_runtime < curr.virtual_runtime) {
            need_resched = true;
        }
        // Update min_vruntime (only increases to prevent starvation).
        const curr_vr = if (!isIdle(curr)) curr.virtual_runtime else std.math.maxInt(u64);
        const new_min = @min(best.virtual_runtime, curr_vr);
        if (new_min > min_vruntime) {
            min_vruntime = new_min;
        }
    } else if (!isIdle(curr) and curr.virtual_runtime > min_vruntime) {
        min_vruntime = curr.virtual_runtime;
    }
}

/// Voluntarily yield CPU to another thread.
pub fn yield() void {
    const held = lock.guard();

    const curr = current_thread orelse {
        held.release();
        return;
    };

    curr.state = .ready;
    enqueueLocked(curr);

    const next = pickNextAndDequeue();
    if (next == curr) {
        curr.state = .running;
        held.release();
        return;
    }
    if (comptime trace.debug_kernel) trace.emit(.sched_yield, curr.id, next.id, 0);
    switchTo(next, held);
}

/// Block current thread until wake() is called.
pub fn block(wait_obj: ?*anyopaque) void {
    const held = lock.guard();

    const curr = current_thread orelse {
        held.release();
        return;
    };

    curr.blocked_on = wait_obj;
    curr.state = .blocked;
    const wait_ptr = if (wait_obj) |p| @intFromPtr(p) else 0;
    if (comptime trace.debug_kernel) trace.emit(.sched_block, curr.id, wait_ptr, 0);

    switchTo(pickNextAndDequeue(), held);
}

/// Wake a blocked thread, making it runnable.
pub fn wake(t: *Thread) void {
    const held = lock.guard();
    defer held.release();

    if (t.state != .blocked) return;

    t.blocked_on = null;
    enqueueLocked(t);
    if (comptime trace.debug_kernel) trace.emit(.sched_wake, t.id, 0, 0);
}

/// Terminate current thread.
pub fn exit() noreturn {
    const held = lock.guard();

    const curr = current_thread orelse {
        held.release();
        hal.cpu.halt();
    };

    // Clean up FPU ownership before exiting.
    hal.fpu.onThreadExit(curr, @truncate(hal.cpu.currentId()));

    curr.state = .exited;
    if (comptime trace.debug_kernel) trace.emit(.sched_exit, curr.id, 0, 0);

    // Exited threads are never re-enqueued, so switchTo should never return.
    switchTo(pickNextAndDequeue(), held);
    @panic(panic_msg.EXITED_THREAD_SCHEDULED);
}

/// Called from trap return path (Zig code).
pub fn maybeReschedule() void {
    if (!need_resched) return;

    const held = lock.guard();
    need_resched = false;

    const curr = current_thread orelse {
        held.release();
        return;
    };

    const next = pickNextAndDequeue();
    if (next == curr) {
        held.release();
        return;
    }

    if (curr.state == .running) {
        curr.state = .ready;
        enqueueLocked(curr);
    }
    switchTo(next, held);
}

/// Called from assembly trap epilogue BEFORE trap frame is restored.
/// This is the safe preemption point - the trap frame stays on the current
/// thread's stack, so after context switch and return, we restore correctly.
export fn preemptFromTrap() void {
    const held = lock.guard();
    need_resched = false;

    const curr = current_thread orelse {
        held.release();
        return;
    };

    const next = pickNextAndDequeue();
    if (next == curr) {
        held.release();
        return;
    }

    if (curr.state == .running) {
        curr.state = .ready;
        enqueueLocked(curr);
    }
    if (comptime trace.debug_kernel) trace.emit(.sched_preempt, curr.id, next.id, 0);
    switchTo(next, held);
    // Returns here after being rescheduled back.
    // Assembly will then restore trap frame and eret/sret.
}

/// Caller must hold lock (released before switch).
inline fn switchTo(target: *Thread, held: sync.SpinLock.Held) void {
    const prev = current_thread orelse {
        held.release();
        return;
    };

    if (prev == target) {
        held.release();
        return;
    }

    // Use interrupt state from when lock was acquired, not current state.
    // The lock guard already disabled interrupts, so disableInterrupts()
    // would always return false here.
    prev.context.irq_enabled = if (held.irq_was_enabled) 1 else 0;

    current_thread = target;
    target.state = .running;
    if (comptime trace.debug_kernel) trace.emit(.sched_switch, prev.id, target.id, 0);

    // Lazy FPU: disable FPU so new thread traps on first use.
    hal.fpu.onContextSwitch(@truncate(hal.cpu.currentId()));

    held.releaseNoIrqRestore();

    // setKernelStack not called:
    // - ARM64 SP_EL1 is live (would corrupt stack),
    // - RISC-V sscratch safe but unneeded for kernel-to-kernel switches.
    hal.context.switchContext(&prev.context, &target.context);

    // TODO(smp): Memory barrier needed - other CPU's writes must be visible.
}

/// Check if scheduler has been initialized.
pub fn isInitialized() bool {
    return current_thread != null;
}

/// Return kernel process for creating system threads.
pub fn getKernelProcess() *Process {
    return kernel_process;
}

/// Called once from kmain to leave boot stack.
pub fn enterIdle() noreturn {
    const idle = idle_thread orelse @panic(panic_msg.ENTER_IDLE_BEFORE_INIT);

    const irq_was_enabled = hal.cpu.disableInterrupts();
    boot_context.irq_enabled = if (irq_was_enabled) 1 else 0;

    idle.context.irq_enabled = 1;
    idle.state = .running;
    current_thread = idle;

    hal.context.switchContext(&boot_context, &idle.context);
    unreachable;
}

test "scales vruntime delta inversely with weight" {
    const base: u64 = task.SCHED_BASE_WEIGHT;
    const elapsed: u64 = task.SCHED_TIME_SLICE_NS;

    const delta_normal = elapsed * base / base;
    try std.testing.expectEqual(elapsed, delta_normal);

    const delta_high = elapsed * base / (base * 2);
    try std.testing.expectEqual(elapsed / 2, delta_high);

    const delta_low = elapsed * base / (base / 2);
    try std.testing.expectEqual(elapsed * 2, delta_low);
}
