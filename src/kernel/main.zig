//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after physInit() enables MMU and switches to
//! higher-half addresses. We finalize the virtual address space transition,
//! initialize physical memory manager and clock, then enter the idle loop.

const std = @import("std");

const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const hal = @import("hal/hal.zig");
const hwinfo = @import("hwinfo/hwinfo.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");
const test_markers = @import("test_markers");

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
    _ = @import("c_compat.zig"); // C stdlib shim
}

fn printHwInfo() void {
    const hw = &hwinfo.info;
    console.print("[6] DTB: ");
    console.printDec(hw.cpu_count);
    console.print(" CPUs, ");
    console.printDec(hw.total_memory / (1024 * 1024));
    console.print(" MB RAM, ");
    console.printDec(hw.reserved_region_count);
    console.print(" reserved regions\n");
}

fn testPmm() void {
    const before = pmm.freeCount();

    // Test single page alloc/free
    const p1 = pmm.allocPage() orelse {
        console.print("PMM: alloc FAIL\n");
        return;
    };
    const p2 = pmm.allocPage() orelse {
        console.print("PMM: alloc FAIL\n");
        return;
    };
    pmm.freePage(p1);
    pmm.freePage(p2);

    // Test contiguous allocation
    const pages = pmm.allocContiguous(4, 0) orelse {
        console.print("PMM: contiguous FAIL\n");
        return;
    };
    pmm.freeContiguous(pages, 4) catch {
        console.print("PMM: freeContiguous FAIL\n");
        return;
    };

    // Verify no leaks
    if (pmm.freeCount() != before) {
        console.print("PMM: leak detected\n");
        return;
    }
}

fn testClock() void {
    while (clock.getTickCount() < 10) {
        hal.cpu.waitForInterrupt();
    }
}

/// Kernel main, called from boot.zig after MMU enables higher-half mapping.
export fn kmain() noreturn {
    hal.virtInit();

    printHwInfo();

    pmm.init();
    console.print("[7] PMM: ");
    console.printDec(pmm.freeCount());
    console.print("/");
    console.printDec(pmm.totalPages());
    console.print(" pages free\n");
    testPmm();

    hal.interrupt.init();
    clock.init();
    console.print("[8] CLK: timer ready\n");
    testClock();

    console.print("\n" ++ test_markers.BOOT_OK ++ "\n");
    hal.cpu.halt();
}

var panic_once: sync.Once = .{};

/// Kernel panic handler. Prints message and halts. Guards against double panic.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = hal.cpu.disableInterrupts();
    if (!panic_once.tryOnce()) hal.cpu.halt();

    // Use printUnsafe to avoid potential deadlock if panic occurred
    // while console lock was held
    console.printUnsafe("\n" ++ test_markers.PANIC ++ " ");
    console.printUnsafe(msg);
    console.printUnsafe("\n");
    hal.cpu.halt();
}
