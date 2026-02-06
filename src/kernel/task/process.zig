//! Process Management.
//!
//! A process is a resource container: threads within a process share address
//! space and capabilities. Currently minimal (ID + thread list). Future: page
//! tables, handle table, parent/child relationships.

const std = @import("std");

const allocator = @import("../allocator/allocator.zig");
const sync = @import("../sync/sync.zig");

const Thread = @import("thread.zig").Thread;

const panic_msg = struct {
    const ACTIVE_THREADS = "process: destroy called with active threads";
    const INVALID_POINTER = "process: invalid process pointer";
};

const PROCESS_SIZE = @sizeOf(Process);

pub const ProcessId = u32;

/// Process control block. Resource container for threads sharing address space.
pub const Process = struct {
    id: ProcessId,
    threads: ?*Thread, // Head of thread list
    thread_count: u32,
    state: State,

    pub const State = enum { active, exiting, zombie };

    pub fn addThread(self: *Process, t: *Thread) void {
        t.process = self;
        t.process_next = self.threads;
        self.threads = t;
        self.thread_count += 1;
    }

    /// Returns true if this was the last thread.
    pub fn removeThread(self: *Process, t: *Thread) bool {
        var prev: ?*Thread = null;
        var curr = self.threads;
        while (curr) |c| {
            if (c == t) {
                if (prev) |p| {
                    p.process_next = c.process_next;
                } else {
                    self.threads = c.process_next;
                }
                c.process_next = null;
                self.thread_count -= 1;
                return self.thread_count == 0;
            }
            prev = c;
            curr = c.process_next;
        }
        return false;
    }
};

var next_id: ProcessId = 1;
var lock: sync.SpinLock = .{};

pub fn init() void {}

/// Create new process. Returns null on OOM.
pub fn create() ?*Process {
    const proc_bytes = allocator.alloc(PROCESS_SIZE, @alignOf(Process)) catch return null;
    const proc: *Process = @ptrCast(@alignCast(proc_bytes));

    const held = lock.guard();
    defer held.release();

    proc.* = .{
        .id = next_id,
        .threads = null,
        .thread_count = 0,
        .state = .active,
    };
    next_id +|= 1;

    return proc;
}

/// Process must have no threads.
pub fn destroy(proc: *Process) void {
    if (proc.thread_count != 0) {
        @panic(panic_msg.ACTIVE_THREADS);
    }

    const proc_bytes: *u8 = @ptrCast(proc);
    allocator.free(proc_bytes) catch {
        @panic(panic_msg.INVALID_POINTER);
    };
}

test "tracks thread count and returns true on last removal" {
    var proc = Process{
        .id = 1,
        .threads = null,
        .thread_count = 0,
        .state = .active,
    };

    var t1 = Thread{
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
        .fpu_state = .{},
    };

    var t2 = Thread{
        .id = 2,
        .process = undefined,
        .state = .ready,
        .context = .{},
        .stack = null,
        .rb_node = .{},
        .blocked_on = null,
        .weight = 1024,
        .virtual_runtime = 0,
        .process_next = null,
        .fpu_state = .{},
    };

    proc.addThread(&t1);
    try std.testing.expectEqual(@as(u32, 1), proc.thread_count);
    try std.testing.expectEqual(&t1, proc.threads.?);

    proc.addThread(&t2);
    try std.testing.expectEqual(@as(u32, 2), proc.thread_count);
    try std.testing.expectEqual(&t2, proc.threads.?);

    // Remove t2 (head)
    const last1 = proc.removeThread(&t2);
    try std.testing.expect(!last1);
    try std.testing.expectEqual(@as(u32, 1), proc.thread_count);

    // Remove t1 (last thread)
    const last2 = proc.removeThread(&t1);
    try std.testing.expect(last2);
    try std.testing.expectEqual(@as(u32, 0), proc.thread_count);
}
