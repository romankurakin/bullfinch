//! Boot sequence logging.
//!
//! Keep early boot output compact and stable for smoke-log comparison.

use kernel::hwinfo::HardwareInfo;

use crate::console::Console;

pub const STAGES: usize = 10;

const MEGABYTE: usize = 1024 * 1024;
const STAGE_NAME_WIDTH: usize = 9;

pub fn header() {
    Console::new().print("[BOOT:STARTED]\n");
}

pub fn uart() {
    stage(1, "boot", "console ready");
}

pub fn trap() {
    stage(2, "trap", "exception handlers set");
}

pub fn mmu() {
    stage(3, "mmu", "virtual memory enabled");
}

pub fn virt() {
    stage(4, "mmu", "low addresses unmapped");
}

pub fn dtb(info: &HardwareInfo) {
    let mut out = Console::new();
    stage_prefix(&mut out, 5, "hwinfo");
    out.print_dec_usize(info.cpu_count);
    out.print(" cpus, ");
    out.print_dec_usize(info.total_memory / MEGABYTE);
    out.print(" MB\n");
    if info.dropped_memory_regions > 0 {
        stage_prefix(&mut out, 5, "hwinfo");
        out.print("warning: dropped ");
        out.print_dec_usize(info.dropped_memory_regions);
        out.print(" memory region(s) (limit reached)\n");
    }
    if info.dropped_reserved_regions > 0 {
        stage_prefix(&mut out, 5, "hwinfo");
        out.print("warning: dropped ");
        out.print_dec_usize(info.dropped_reserved_regions);
        out.print(" reserved region(s) (limit reached)\n");
    }
}

pub fn pmm() {
    let mut out = Console::new();
    stage_prefix(&mut out, 6, "pmm");
    out.print_dec_usize(kernel::pmm::arena_count());
    out.print(" arenas, ");
    out.print_dec_usize(kernel::pmm::total_pages());
    out.print(" pages\n");
}

pub fn trace() {
    stage(7, "trace", "ring ready");
}

pub fn clock() {
    stage(8, "clock", "timer ready");
}

pub fn task() {
    stage(9, "task", "scheduler ready");
}

pub fn idle() {
    stage(10, "task", "entering idle thread");
}

fn stage(number: usize, name: &str, message: &str) {
    let mut out = Console::new();
    stage_prefix(&mut out, number, name);
    out.print(message);
    out.print("\n");
}

fn stage_prefix(out: &mut Console, number: usize, name: &str) {
    out.print("[");
    print_two_digits(out, number);
    out.print("/");
    print_two_digits(out, STAGES);
    out.print("] ");
    print_padded(out, name, STAGE_NAME_WIDTH);
    out.print(" ");
}

fn print_two_digits(out: &mut Console, value: usize) {
    if value < 10 {
        out.print("0");
    }
    out.print_dec_usize(value);
}

fn print_padded(out: &mut Console, text: &str, width: usize) {
    out.print(text);
    for _ in text.len()..width {
        out.print(" ");
    }
}
