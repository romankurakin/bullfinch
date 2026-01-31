//! Kernel trace ring buffer.
//!
//! Per-CPU fixed-size ring buffers for lightweight event tracing.
//! Lock-free design using relaxed atomics for SMP scalability.
//!
//! Safe to call from scheduler with scheduler lock held.

const std = @import("std");

const clock = @import("../clock/clock.zig");
const console = @import("../console/console.zig");
const fmt = @import("../trap/fmt.zig");
const hal = @import("../hal/hal.zig");
const hwinfo = @import("../hwinfo/hwinfo.zig");
const limits = @import("../limits.zig");

const RING_SIZE: u32 = 256;
const RING_MASK: u32 = RING_SIZE - 1;

comptime {
    if ((RING_SIZE & (RING_SIZE - 1)) != 0)
        @compileError("trace: RING_SIZE must be power of two");
}

pub const EventId = enum(u16) {
    sched_switch = 1,
    sched_enqueue = 2,
    sched_dequeue = 3,
    sched_tick = 4,
    trap_enter = 5,
    trap_exit = 6,
    sched_block = 7,
    sched_wake = 8,
    sched_yield = 9,
    sched_exit = 10,
    sched_preempt = 11,
};

pub const Event = extern struct {
    ts: u64,
    cpu: u16,
    id: u16,
    a: usize,
    b: usize,
    c: usize,
};

const Ring = struct {
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    events: [RING_SIZE]Event = [_]Event{.{ .ts = 0, .cpu = 0, .id = 0, .a = 0, .b = 0, .c = 0 }} ** RING_SIZE,
};

var rings: [limits.MAX_CPUS]Ring = [_]Ring{.{}} ** limits.MAX_CPUS;
var active_cpus: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var enabled_mask: std.atomic.Value(u64) = std.atomic.Value(u64).init(0xffff_ffff_ffff_ffff);

/// Initialize trace subsystem. Safe to call before scheduler exists.
pub fn init() void {
    const count = hwinfo.info.cpu_count;
    const capped: u32 = if (count == 0) 1 else if (count > limits.MAX_CPUS) limits.MAX_CPUS else count;
    @memset(rings[0..capped], .{});
    active_cpus.store(capped, .release);
    enabled.store(true, .release);
}

/// Filter events by bitmask. Bit N enables EventId N.
pub fn setMask(mask: u64) void {
    enabled_mask.store(mask, .release);
}

/// Return number of CPUs with active trace rings.
pub fn activeCpuCount() u32 {
    return active_cpus.load(.monotonic);
}

inline fn currentCpu() u16 {
    const id = hal.cpu.currentId();
    if (id >= active_cpus.load(.monotonic)) return 0;
    return @truncate(id);
}

/// Record event with timestamp. Called from scheduler and trap handlers.
/// Caller must have IRQs disabled (scheduler lock or trap context).
pub inline fn emit(id: EventId, a: usize, b: usize, c: usize) void {
    if (!enabled.load(.monotonic)) return;
    const bit_val = @intFromEnum(id);
    if (bit_val >= 64) return;
    const bit: u6 = @truncate(bit_val);
    if ((enabled_mask.load(.monotonic) & (@as(u64, 1) << bit)) == 0) return;
    const cpu = currentCpu();
    const ring = &rings[cpu];
    // Relaxed RMW: per-CPU ring, no cross-CPU contention. Monotonic sufficient.
    const idx = ring.head.fetchAdd(1, .monotonic) & RING_MASK;
    ring.events[idx] = .{
        .ts = clock.getMonotonicNs(),
        .cpu = cpu,
        .id = @intFromEnum(id),
        .a = a,
        .b = b,
        .c = c,
    };
}

/// Dump recent events from all CPUs to console. Use in panic handlers.
pub fn dumpAllRecent(count: u32) void {
    if (!enabled.load(.monotonic)) return;
    const cpus = active_cpus.load(.monotonic);
    var cpu: u32 = 0;
    while (cpu < cpus) : (cpu += 1) {
        dumpRecent(@truncate(cpu), count);
    }
}

/// Dump recent events from specified CPU to console.
pub fn dumpRecent(cpu: u16, count: u32) void {
    if (!enabled.load(.monotonic)) return;
    if (cpu >= active_cpus.load(.monotonic)) return;
    const ring = &rings[cpu];
    // Acquire ensures we see all events written before this head value.
    const head = ring.head.load(.acquire);
    if (head == 0) {
        console.printUnsafe("\n[trace] cpu ");
        const dec = fmt.formatDecimal(cpu);
        console.printUnsafe(dec.buf[0..dec.len]);
        console.printUnsafe(" (empty)\n");
        return;
    }
    const start = if (head > count) head - count else 0;

    console.printUnsafe("\n[trace] cpu ");
    const dec = fmt.formatDecimal(cpu);
    console.printUnsafe(dec.buf[0..dec.len]);
    console.printUnsafe("\n");
    const widths = computeColumnWidths(ring, start, head);
    console.printUnsafe("  ");
    printPadded("event", widths.event);
    console.printUnsafe("  ");
    printPaddedLeft("time", widths.time_us);
    console.printUnsafe("  ");
    printPaddedLeft("delta", widths.delta_us);
    console.printUnsafe("  ");
    console.printUnsafe("detail\n");

    var i = start;
    var prev_ts: u64 = 0;
    var have_prev = false;
    while (i < head) : (i += 1) {
        const ev = ring.events[i & RING_MASK];
        const delta_ns = if (have_prev) ev.ts - prev_ts else 0;
        printEvent(ev, widths, delta_ns);
        prev_ts = ev.ts;
        have_prev = true;
    }
}

fn printEvent(ev: Event, widths: ColumnWidths, delta_ns: u64) void {
    console.printUnsafe("  ");
    const name = shortName(@enumFromInt(ev.id));
    printPadded(name, widths.event);
    console.printUnsafe("  ");
    const time_us: u64 = ev.ts / 1000;
    const delta_us: u64 = delta_ns / 1000;
    printDecPadded(time_us, widths.time_us);
    console.printUnsafe("  ");
    printDecPadded(delta_us, widths.delta_us);
    console.printUnsafe("  ");
    printDetail(ev);
    console.printUnsafe("\n");
}

fn shortName(id: EventId) []const u8 {
    return switch (id) {
        .sched_switch => "sched_switch",
        .sched_enqueue => "sched_enqueue",
        .sched_dequeue => "sched_dequeue",
        .sched_tick => "sched_tick",
        .sched_block => "sched_block",
        .sched_wake => "sched_wake",
        .sched_yield => "sched_yield",
        .sched_exit => "sched_exit",
        .sched_preempt => "sched_preempt",
        .trap_enter => "irq",
        .trap_exit => "irq",
    };
}

fn printDetail(ev: Event) void {
    switch (@as(EventId, @enumFromInt(ev.id))) {
        .sched_switch => {
            console.printUnsafe("from=");
            printDec(ev.a);
            console.printUnsafe(" to=");
            printDec(ev.b);
        },
        .sched_enqueue => {
            console.printUnsafe("tid=");
            printDec(ev.a);
        },
        .sched_dequeue => {
            console.printUnsafe("tid=");
            printDec(ev.a);
        },
        .sched_tick => {
            console.printUnsafe("tid=");
            printDec(ev.a);
            console.printUnsafe(" vr=");
            printHexWithPrefix(ev.b, 16);
        },
        .sched_block => {
            console.printUnsafe("tid=");
            printDec(ev.a);
            console.printUnsafe(" wait=");
            printHexWithPrefix(ev.b, 16);
        },
        .sched_wake => {
            console.printUnsafe("tid=");
            printDec(ev.a);
        },
        .sched_yield => {
            console.printUnsafe("from=");
            printDec(ev.a);
            console.printUnsafe(" to=");
            printDec(ev.b);
        },
        .sched_exit => {
            console.printUnsafe("tid=");
            printDec(ev.a);
        },
        .sched_preempt => {
            console.printUnsafe("from=");
            printDec(ev.a);
            console.printUnsafe(" to=");
            printDec(ev.b);
        },
        .trap_enter, .trap_exit => {
            console.printUnsafe("code=");
            printHexWithPrefix(ev.a, 16);
        },
    }
}

fn printHexPadded(value: usize, width: usize) void {
    const hex = fmt.formatHex(value);
    const pad = width -| hex.len;
    var i: usize = 0;
    while (i < pad) : (i += 1) console.printUnsafe("0");
    console.printUnsafe(hex[0..hex.len]);
}

fn printHexWithPrefix(value: usize, digits: usize) void {
    console.printUnsafe("0x");
    printHexPadded(value, digits);
}

fn printPadded(text: []const u8, width: usize) void {
    console.printUnsafe(text);
    var pad: usize = width -| text.len;
    while (pad > 0) : (pad -= 1) console.printUnsafe(" ");
}

fn printPaddedLeft(text: []const u8, width: usize) void {
    var pad: usize = width -| text.len;
    while (pad > 0) : (pad -= 1) console.printUnsafe(" ");
    console.printUnsafe(text);
}

const ColumnWidths = struct {
    event: usize,
    time_us: usize,
    delta_us: usize,
};

fn computeColumnWidths(ring: *Ring, start: usize, head: usize) ColumnWidths {
    var max_event: usize = "event".len;
    var max_time_us: u64 = 0;
    var max_delta_us: u64 = 0;
    var prev_ts: u64 = 0;
    var have_prev = false;
    var i = start;
    while (i < head) : (i += 1) {
        const ev = ring.events[i & RING_MASK];
        const name = shortName(@enumFromInt(ev.id));
        if (name.len > max_event) max_event = name.len;
        const time_us: u64 = ev.ts / 1000;
        if (time_us > max_time_us) max_time_us = time_us;
        if (have_prev) {
            const delta_us: u64 = (ev.ts - prev_ts) / 1000;
            if (delta_us > max_delta_us) max_delta_us = delta_us;
        }
        prev_ts = ev.ts;
        have_prev = true;
    }

    // Keep widths bounded so columns stay readable on UART.
    const clamped_event = @min(@max(max_event, 8), 14);
    const time_width = @max("time_us".len, decDigitsU64(max_time_us));
    const delta_width = @max("delta_us".len, decDigitsU64(max_delta_us));
    return .{ .event = clamped_event, .time_us = time_width, .delta_us = delta_width };
}

fn printDec(value: usize) void {
    const dec = fmt.formatDecimal(value);
    console.printUnsafe(dec.buf[0..dec.len]);
}

fn decDigitsU64(value: u64) usize {
    const dec = fmt.formatDecimal(@intCast(value));
    return dec.len;
}

fn printDecPadded(value: u64, width: usize) void {
    const dec = fmt.formatDecimal(@intCast(value));
    var pad: usize = width -| dec.len;
    while (pad > 0) : (pad -= 1) console.printUnsafe(" ");
    console.printUnsafe(dec.buf[0..dec.len]);
}
