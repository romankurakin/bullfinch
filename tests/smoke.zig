//! Smoke Test Runner.
//!
//! Runs pre-built kernels in QEMU, checks for success marker.
//! Build kernels first with: just build-arm64 build-riscv64

const std = @import("std");

const BOOT_OK = "[BOOT:OK]";
const PANIC = "[PANIC]";

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

    const gpa = std.heap.page_allocator;
    const stdout = qemu.stdout.?;
    const stderr = qemu.stderr.?;
    const Streams = enum { stdout, stderr };
    var poller = std.io.poll(gpa, Streams, .{ .stdout = stdout, .stderr = stderr });
    defer poller.deinit();

    const max_keep: usize = 4096;
    const deadline: i128 = std.time.nanoTimestamp() + 15 * std.time.ns_per_s;

    while (std.time.nanoTimestamp() < deadline) {
        _ = try poller.pollTimeout(10 * std.time.ns_per_ms);
        trimReader(poller.reader(.stdout), max_keep);
        trimReader(poller.reader(.stderr), max_keep);

        const out_stdout = poller.reader(.stdout).buffered();
        const out_stderr = poller.reader(.stderr).buffered();
        const saw_ok = std.mem.indexOf(u8, out_stdout, BOOT_OK) != null or
            std.mem.indexOf(u8, out_stderr, BOOT_OK) != null;
        const saw_panic = std.mem.indexOf(u8, out_stdout, PANIC) != null or
            std.mem.indexOf(u8, out_stderr, PANIC) != null;

        if (saw_ok) {
            _ = qemu.kill() catch {};
            _ = qemu.wait() catch {};
            std.debug.print("{s}: PASS\n", .{name});
            return true;
        }
        if (saw_panic) {
            _ = qemu.kill() catch {};
            _ = qemu.wait() catch {};
            const out = joinOutput(out_stdout, out_stderr);
            defer if (out.owned) gpa.free(out.buf);
            std.debug.print("{s}: FAIL (panic)\n--- output ---\n{s}\n--- end ---\n", .{ name, out.buf });
            return false;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    _ = qemu.kill() catch {};
    _ = qemu.wait() catch {};
    const out_stdout = poller.reader(.stdout).buffered();
    const out_stderr = poller.reader(.stderr).buffered();
    const out = joinOutput(out_stdout, out_stderr);
    defer if (out.owned) gpa.free(out.buf);
    std.debug.print("{s}: FAIL (timeout)\n--- output ---\n{s}\n--- end ---\n", .{ name, out.buf });
    return false;
}

fn trimReader(reader: *std.io.Reader, keep: usize) void {
    const len = reader.bufferedLen();
    if (len <= keep) return;
    const drop = len - keep;
    _ = reader.discard(std.io.Limit.limited(drop)) catch {};
}

const JoinedOutput = struct {
    buf: []const u8,
    owned: bool,
};

fn joinOutput(stdout: []const u8, stderr: []const u8) JoinedOutput {
    if (stderr.len == 0) return .{ .buf = stdout, .owned = false };
    const gpa = std.heap.page_allocator;
    const total = stdout.len + stderr.len;
    var out = gpa.alloc(u8, total) catch return .{ .buf = stdout, .owned = false };
    std.mem.copyForwards(u8, out[0..stdout.len], stdout);
    std.mem.copyForwards(u8, out[stdout.len..], stderr);
    return .{ .buf = out, .owned = true };
}
