//! Kernel Entry Point.
//!
//! Control arrives from boot.zig after physInit() enables MMU and switches to
//! higher-half addresses. We finalize the virtual address space transition,
//! initialize physical memory manager and clock, then enter the idle loop.

const std = @import("std");

const boot_log = @import("boot/log.zig");
const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const hal = @import("hal/hal.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");
const test_markers = @import("test_markers");

comptime {
    _ = hal.boot; // Force boot module inclusion for entry point
    _ = @import("c_compat.zig"); // C stdlib shim
}

fn testClock() void {
    while (clock.getTickCount() < 10) {
        hal.cpu.waitForInterrupt();
    }
}

/// Kernel main, called from boot.zig after MMU enables higher-half mapping.
export fn kmain() noreturn {
    hal.virtInit();

    boot_log.dtb();

    pmm.init();
    boot_log.pmm();

    hal.interrupt.init();
    clock.init();
    boot_log.clock();
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
