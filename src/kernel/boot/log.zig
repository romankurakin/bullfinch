//! Boot Sequence Logging.
//!
//! Centralized boot progress messages with consistent formatting.
//!
//! Format: "[N/T] name message"
//! - N/T: stage progress
//! - name: subsystem, padded to a consistent column
//! - message: description

const builtin = @import("builtin");
const console = @import("../console/console.zig");
const hwinfo = @import("../hwinfo/hwinfo.zig");
const pmm_mod = @import("../pmm/pmm.zig");

/// Total boot stages. Update when adding/removing stages.
pub const STAGES: u8 = 10;

const MB: usize = 1024 * 1024;

const STAGE_NAMES = [_][]const u8{
    "uart",
    "trap",
    "mmu",
    "virt",
    "dtb",
    "pmm",
    "trace",
    "clock",
    "task",
    "idle",
};

const STAGE_NAME_WIDTH: usize = blk: {
    var max: usize = 0;
    for (STAGE_NAMES) |name| {
        if (name.len > max) max = name.len;
    }
    break :blk max;
};

pub fn header() void {
    console.print("Bullfinch\n\n");
}

/// Print stage prefix: "[N/T] name " with padded name column.
/// Use for stages with dynamic content. Caller must print message and newline.
fn stagePrefix(n: u8, name: []const u8) void {
    console.print("[");
    if (n < 10) console.print("0");
    console.printDec(n);
    console.print("/");
    if (STAGES < 10) console.print("0");
    console.printDec(STAGES);
    console.print("] ");

    printPadded(name, STAGE_NAME_WIDTH);
    console.print(" ");
}

/// Print a boot stage message: "[N/T] name message\n"
fn stage(n: u8, name: []const u8, message: []const u8) void {
    stagePrefix(n, name);
    console.print(message);
    console.print("\n");
}

pub fn uart() void {
    stage(1, "uart", "console ready");
}

pub fn trap() void {
    stage(2, "trap", "exception handlers set");
}

pub fn mmu() void {
    stage(3, "mmu", "virtual memory enabled");
}

pub fn virt() void {
    stage(4, "virt", "low addresses unmapped");
}

pub fn dtb() void {
    const hw = &hwinfo.info;
    stagePrefix(5, "dtb");
    console.printDec(hw.cpu_count);
    console.print(" cpus, ");
    console.printDec(hw.total_memory / MB);
    console.print(" MB\n");
}

pub fn pmm() void {
    const arenas = pmm_mod.arenaCount();
    const pages = pmm_mod.totalPages();
    const pages_k = pages / 1000;

    stagePrefix(6, "pmm");
    console.printDec(arenas);
    console.print(if (arenas == 1) " arena, " else " arenas, ");
    console.printDec(pages_k);
    console.print("k pages\n");
}

pub fn trace() void {
    stage(7, "trace", "ring ready");
}

pub fn clock() void {
    stage(8, "clock", "timer ready");
}

pub fn task() void {
    stage(9, "task", "scheduler ready");
}

pub fn idle() void {
    stage(10, "idle", "entering idle thread");
}

fn printPadded(text: []const u8, width: usize) void {
    console.print(text);
    var pad: usize = width -| text.len;
    while (pad > 0) : (pad -= 1) console.print(" ");
}
