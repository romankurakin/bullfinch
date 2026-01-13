//! Simple smoke test runner.
//! Runs pre-built kernels in QEMU, checks for success marker.
//! Build kernels first with: just build-arm64 build-riscv64

const std = @import("std");
const markers = @import("test_markers");

pub fn main() !u8 {
    const arm64 = try runQemu("arm64", &.{
        "qemu-system-aarch64", "-machine", "virt,gic-version=3",
        "-cpu", "cortex-a76", "-smp", "2", "-m", "2G", "-nographic",
        "-kernel", "zig-out/bin/kernel-arm64.bin",
    });

    const riscv = try runQemu("riscv64", &.{
        "qemu-system-riscv64", "-machine", "virt", "-smp", "2",
        "-m", "2G", "-nographic", "-bios", "default",
        "-kernel", "zig-out/bin/kernel-riscv64",
    });

    const passed = @as(u8, if (arm64) 1 else 0) + @as(u8, if (riscv) 1 else 0);
    std.debug.print("\n{}/2 passed\n", .{passed});
    return if (passed == 2) 0 else 1;
}

fn runQemu(name: []const u8, cmd: []const []const u8) !bool {
    std.debug.print("{s}... ", .{name});

    var qemu = std.process.Child.init(cmd, std.heap.page_allocator);
    qemu.stdout_behavior = .Pipe;
    qemu.stderr_behavior = .Pipe;
    try qemu.spawn();

    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    const deadline: i128 = std.time.nanoTimestamp() + 15 * std.time.ns_per_s;

    while (std.time.nanoTimestamp() < deadline) {
        len += qemu.stdout.?.read(buf[len..]) catch 0;
        if (std.mem.indexOf(u8, buf[0..len], markers.BOOT_OK) != null) {
            _ = qemu.kill() catch {};
            _ = qemu.wait() catch {};
            std.debug.print("PASS\n", .{});
            return true;
        }
        if (std.mem.indexOf(u8, buf[0..len], markers.PANIC) != null) {
            _ = qemu.kill() catch {};
            _ = qemu.wait() catch {};
            std.debug.print("FAIL (panic)\n", .{});
            return false;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    _ = qemu.kill() catch {};
    _ = qemu.wait() catch {};
    std.debug.print("FAIL (timeout)\n", .{});
    return false;
}
