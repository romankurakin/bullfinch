//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after physInit() enables MMU and switches to
//! higher-half addresses. We finalize the virtual address space transition,
//! initialize physical memory manager and clock, then enter the idle loop.

const builtin = @import("builtin");
const std = @import("std");

const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const fdt = @import("fdt/fdt.zig");
const hal = @import("hal/hal.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");

const panic_msg = struct {
    const NO_DTB = "BOOT: no DTB - cannot discover hardware";
};

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
    _ = @import("c_compat.zig"); // C stdlib shim
}

fn printDtbInfo(dtb: fdt.Fdt) void {
    console.print("DTB: ");
    console.printDec(fdt.getCpuCount(dtb));
    console.print(" CPUs, ");
    console.printDec(fdt.getTotalMemory(dtb) / (1024 * 1024));
    console.print(" MB RAM\n");

    var reserved = fdt.getReservedRegions(dtb);
    while (reserved.next()) |region| {
        console.print("DTB: reserved ");
        console.printHex(region.base);
        console.print("-");
        console.printHex(region.base + region.size);
        console.print("\n");
    }
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
    pmm.freeContiguous(pages, 4);

    // Verify no leaks
    if (pmm.freeCount() != before) {
        console.print("PMM: leak detected\n");
        return;
    }

    console.print("PMM: OK\n");
}

fn testClock() void {
    console.print("CLK: waiting 10 ticks\n");
    while (clock.getTickCount() < 10) {
        hal.waitForInterrupt();
    }
    console.print("CLK: timer OK\n");
}

/// Kernel main, called from boot.zig after MMU enables higher-half mapping.
export fn kmain() noreturn {
    hal.virtInit();

    const dtb = hal.getDtb() orelse @panic(panic_msg.NO_DTB);
    printDtbInfo(dtb);

    pmm.init(dtb);
    console.print("PMM: ");
    console.printDec(pmm.freeCount());
    console.print("/");
    console.printDec(pmm.totalPages());
    console.print(" pages free\n");
    testPmm();

    clock.init(dtb);
    testClock();

    console.print("\nBOOT: complete\n");
    hal.halt();
}

var panic_once: sync.Once = .{};

/// Kernel panic handler. Prints message and halts. Guards against double panic.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = hal.disableInterrupts();
    if (!panic_once.tryOnce()) hal.halt();

    console.print("\nPanic: ");
    console.print(msg);
    console.print("\n");
    hal.halt();
}
