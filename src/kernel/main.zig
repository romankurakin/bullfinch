//! Kernel Entry Point.
//!
//! Control arrives after the arch boot path switches to higher-half mappings.
//! We complete the virtual transition, initialize core subsystems, then enter
//! the idle loop.

const std = @import("std");

const boot_init = @import("boot/init.zig");
const boot_log = @import("boot/log.zig");
const clock = @import("clock/clock.zig");
const console = @import("console/console.zig");
const hal = @import("hal/hal.zig");
const kalloc = @import("allocator/allocator.zig");
const pmm = @import("pmm/pmm.zig");
const sync = @import("sync/sync.zig");

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

    hal.interrupt.init();
    clock.init();
    boot_log.clock();
}

/// Kernel entry after arch boot hands off to the common kernel path.
export fn kmain() noreturn {
    // Higher-half mappings are active; virtInit finalizes the transition.
    boot_init.virtInit();

    kernelInit();

    console.print("\n[BOOT:OK]\n");
    hal.cpu.halt();
}

var panic_once: sync.Once = .{};

/// Kernel panic handler. Prints message and halts. Guards against double panic.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = hal.cpu.disableInterrupts();
    if (!panic_once.tryOnce()) hal.cpu.halt();

    // Use printUnsafe to avoid potential deadlock if panic occurred
    // while console lock was held
    console.printUnsafe("\n");
    console.printUnsafe(msg);
    console.printUnsafe("\n");
    hal.cpu.halt();
}
