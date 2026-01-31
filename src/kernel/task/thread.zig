//! Thread Management.
//!
//! A thread is the unit of scheduling. Each thread has its own kernel stack
//! and saved context (callee-saved registers). Threads within the same process
//! share address space and capabilities.
//!
//! TODO(security): Add shadow call stack field for ROP protection.

const std = @import("std");

const allocator = @import("../allocator/allocator.zig");
const hal = @import("../hal/hal.zig");
const sync = @import("../sync/sync.zig");
const task = @import("task.zig");

const Process = @import("process.zig").Process;
const rbtree = @import("rbtree.zig");
const Stack = @import("stack.zig").Stack;

const panic_msg = struct {
    const INVALID_POINTER = "thread: invalid thread pointer";
};

const THREAD_SIZE = @sizeOf(Thread);

pub const ThreadId = u32;

/// Thread control block. Kernel's view of an execution context.
pub const Thread = struct {
    id: ThreadId,
    process: *Process,
    state: State,
    context: hal.context.Context align(16),
    stack: ?Stack,
    rb_node: rbtree.Node, // Runqueue linkage (rbtree)
    blocked_on: ?*anyopaque, // For Liedtke-style direct switch
    weight: u32, // CFS weight: higher = more CPU time
    virtual_runtime: u64, // CFS vruntime: lower = run sooner
    process_next: ?*Thread, // Process thread list linkage

    pub const State = enum { ready, running, blocked, exited };

    pub fn isRunnable(self: *const Thread) bool {
        return self.state == .ready or self.state == .running;
    }
};

var next_id: ThreadId = 1;
var lock: sync.SpinLock = .{};

/// Initialize thread subsystem. Caller provides the scheduler exit function.
pub fn init(scheduler_exit: hal.context.ExitFn) void {
    hal.context.setExitFn(scheduler_exit);
}

pub const EntryFn = hal.context.EntryFn;

inline fn optionalPtrToInt(ptr: ?*anyopaque) usize {
    return if (ptr) |p| @intFromPtr(p) else 0;
}

fn initThreadStruct(
    t: *Thread,
    tid: ThreadId,
    proc: *Process,
    stack: Stack,
    entry: EntryFn,
    arg: ?*anyopaque,
) void {
    t.* = .{
        .id = tid,
        .process = proc,
        .state = .ready,
        .context = hal.context.Context.init(
            @intFromPtr(&hal.context.threadTrampoline),
            stack.top(),
        ),
        .stack = stack,
        .rb_node = .{},
        .blocked_on = null,
        .weight = task.SCHED_BASE_WEIGHT,
        .virtual_runtime = 0,
        .process_next = null,
    };
    t.context.setEntryData(@intFromPtr(entry), optionalPtrToInt(arg));
}

/// Create thread in process with given entry point. Returns null on OOM.
pub fn create(proc: *Process, entry: EntryFn, arg: ?*anyopaque) ?*Thread {
    const stack = Stack.create() orelse return null;

    const thread_bytes = allocator.alloc(THREAD_SIZE, @alignOf(Thread)) catch {
        stack.destroy();
        return null;
    };
    const t: *Thread = @ptrCast(@alignCast(thread_bytes));

    const tid = allocateId();
    initThreadStruct(t, tid, proc, stack, entry, arg);
    proc.addThread(t);

    return t;
}

fn allocateId() ThreadId {
    const held = lock.guard();
    defer held.release();
    const tid = next_id;
    next_id +|= 1;
    return tid;
}

/// Thread must be exited and off all queues.
pub fn destroy(t: *Thread) void {
    if (t.stack) |stack| {
        stack.destroy();
    }
    _ = t.process.removeThread(t);

    const thread_bytes: *u8 = @ptrCast(t);
    allocator.free(thread_bytes) catch {
        @panic(panic_msg.INVALID_POINTER);
    };
}

/// Create idle thread with minimum weight. Runs when no other threads ready.
pub fn createIdleThread(proc: *Process) ?*Thread {
    const t = create(proc, idleLoop, null) orelse return null;
    t.weight = task.SCHED_MIN_WEIGHT;
    return t;
}

fn idleLoop(_: ?*anyopaque) void {
    while (true) {
        hal.cpu.waitForInterrupt();
    }
}

test "returns true for ready and running states" {
    var thread = Thread{
        .id = 1,
        .process = undefined,
        .state = .ready,
        .context = .{},
        .stack = null,
        .rb_node = .{},
        .blocked_on = null,
        .weight = 1024,
        .virtual_runtime = 0,
        .process_next = null,
    };

    thread.state = .ready;
    try std.testing.expect(thread.isRunnable());

    thread.state = .running;
    try std.testing.expect(thread.isRunnable());

    thread.state = .blocked;
    try std.testing.expect(!thread.isRunnable());

    thread.state = .exited;
    try std.testing.expect(!thread.isRunnable());
}
