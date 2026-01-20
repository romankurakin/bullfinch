//! Boot Sequence Logging.
//!
//! Centralized boot progress messages with consistent formatting.
//!
//! Format: "[N/T] name message"
//! - N/T: stage progress
//! - name: subsystem, 6-char column (5 + separator)
//! - message: description

const builtin = @import("builtin");
const console = @import("../console/console.zig");
const hwinfo = @import("../hwinfo/hwinfo.zig");
const pmm_mod = @import("../pmm/pmm.zig");

/// Total boot stages. Update when adding/removing stages.
pub const STAGES: u8 = 7;

const MB: usize = 1024 * 1024;

const arch_name = switch (builtin.cpu.arch) {
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V",
    else => "unknown",
};

pub fn header() void {
    console.print("Bullfinch (" ++ arch_name ++ ")\n\n");
}

/// Print stage prefix: "[N/T] name " with 6-char name column (5 + separator).
/// Use for stages with dynamic content. Caller must print message and newline.
fn stagePrefix(n: u8, name: []const u8) void {
    console.print("[");
    console.printDec(n);
    console.print("/");
    console.printDec(STAGES);
    console.print("] ");

    console.print(name);
    var pad: usize = 5 -| name.len;
    while (pad > 0) : (pad -= 1) {
        console.print(" ");
    }
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

pub fn clock() void {
    stage(7, "clock", "timer ready");
}
