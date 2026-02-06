//! Kernel Entry Point.
//!
//! Control arrives after the arch boot path switches to higher-half mappings.
//! We complete the virtual transition, initialize core subsystems, then enter
//! the idle loop.

const std = @import("std");

const backtrace = @import("trap/backtrace.zig");
const boot_init = @import("boot/init.zig");
const boot_log = @import("boot/log.zig");
const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const trace = @import("debug/trace.zig");
const hal = @import("hal/hal.zig");
const kalloc = @import("allocator/allocator.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");
const task = @import("task/task.zig");

// Force-include modules with exports called externally (not from Zig).
// Without these references, dead code elimination would remove them.
comptime {
    _ = hal.boot;
    _ = boot_init;
    _ = @import("c_compat.zig");
}

/// Kernel-wide initialization after virtInit completes the address space.
fn kernelInit() void {
    boot_log.dtb();

    const krange = hal.getKernelPhysRange();
    pmm.init(krange.start, krange.end);
    boot_log.pmm();
    kalloc.init();

    trace.init();
    boot_log.trace();

    hal.interrupt.init();
    hal.fpu.bootInit();
    clock.init();
    boot_log.clock();

    task.init();
    clock.setSchedulerTick(task.scheduler.tick);
    boot_log.task();
}

/// Kernel entry after arch boot hands off to the common kernel path.
export fn kmain() noreturn {
    // Higher-half mappings are active; virtInit finalizes the transition.
    boot_init.virtInit();

    kernelInit();

    boot_log.idle();
    console.print("\n[BOOT:OK]\n");
    task.scheduler.enterIdle();
}

var panic_once: sync.Once = .{};

/// Kernel panic handler. Prints message and halts. Guards against double panic.
/// Ignore Zig StackTrace and use a frame-pointer backtrace for one implementation.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = hal.cpu.disableInterrupts();
    if (!panic_once.tryOnce()) hal.cpu.halt();

    console.printUnsafe("\npanic: ");
    console.printUnsafe(msg);
    backtrace.printBacktrace(@frameAddress(), @returnAddress());
    trace.dumpAllRecent(64);
    hal.cpu.halt();
}
