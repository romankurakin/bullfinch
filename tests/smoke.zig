//! Simple smoke test runner.
//! Runs pre-built kernels in QEMU, checks for success marker.
//! Build kernels first with: just build-arm64 build-riscv64

const std = @import("std");
const markers = @import("test_markers");

pub fn main() !u8 {
    var arm64_result: bool = false;
    var riscv_result: bool = false;

    const arm64_thread = try std.Thread.spawn(.{}, runQemuThread, .{ "arm64", &.{
        "qemu-system-aarch64", "-machine",   "virt,gic-version=3",
        "-cpu",                "cortex-a76", "-smp",
        "2",                   "-m",         "2G",
        "-nographic",          "-kernel",    "zig-out/bin/kernel-arm64.bin",
    }, &arm64_result });

    const riscv_thread = try std.Thread.spawn(.{}, runQemuThread, .{ "riscv64", &.{
        "qemu-system-riscv64", "-machine",   "virt",       "-smp",  "2",
        "-m",                  "2G",         "-nographic", "-bios", "default",
        "-kernel",             "zig-out/bin/kernel-riscv64",
    }, &riscv_result });

    arm64_thread.join();
    riscv_thread.join();

    return if (arm64_result and riscv_result) 0 else 1;
}

fn runQemuThread(name: []const u8, cmd: []const []const u8, result: *bool) void {
    result.* = runQemu(name, cmd) catch false;
}

fn runQemu(name: []const u8, cmd: []const []const u8) !bool {
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
            std.debug.print("{s}: PASS\n", .{name});
            return true;
        }
        if (std.mem.indexOf(u8, buf[0..len], markers.PANIC) != null) {
            _ = qemu.kill() catch {};
            _ = qemu.wait() catch {};
            std.debug.print("{s}: FAIL (panic)\n--- output ---\n{s}\n--- end ---\n", .{ name, buf[0..len] });
            return false;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    _ = qemu.kill() catch {};
    _ = qemu.wait() catch {};
    std.debug.print("{s}: FAIL (timeout)\n--- output ---\n{s}\n--- end ---\n", .{ name, buf[0..len] });
    return false;
}
