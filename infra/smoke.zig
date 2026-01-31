//! Smoke Test Runner.
//!
//! Runs pre-built kernels in QEMU, checks for success marker.
//! Reads config from infra/config.json.

const std = @import("std");
const config_mod = @import("config");

const BOOT_OK = "[BOOT:OK]";
const PEEK_TIMEOUT: u32 = 4;

pub fn main() u8 {
    return mainImpl() catch |err| {
        if (err == error.ShowHelp) return 0;
        std.debug.print("smoke: {s}\n", .{@errorName(err)});
        return 2;
    };
}

fn mainImpl() !u8 {
    const gpa = std.heap.page_allocator;
    const opts = try parseArgs(gpa);

    const parsed = try config_mod.parse(gpa);
    defer parsed.deinit();
    const config = parsed.value;

    try std.fs.cwd().makePath("zig-out/tests");

    var passed: usize = 0;
    var failed: usize = 0;

    if (config.smoke.parallel and !opts.peek and config.smoke.variants.len > 1) {
        var threads = try gpa.alloc(std.Thread, config.smoke.variants.len);
        defer gpa.free(threads);
        var results = try gpa.alloc(?bool, config.smoke.variants.len);
        defer gpa.free(results);

        for (config.smoke.variants, 0..) |variant, i| {
            results[i] = null;
            threads[i] = try std.Thread.spawn(.{}, runVariantThread, .{ gpa, opts, config.boards, variant, config.smoke.timeout_secs, &results[i] });
        }
        for (threads) |t| t.join();

        for (results) |r| {
            if (r) |p| {
                if (p) passed += 1 else failed += 1;
            } else {
                failed += 1;
            }
        }
    } else {
        for (config.smoke.variants) |variant| {
            const result = runVariant(gpa, opts, config.boards, variant, config.smoke.timeout_secs) catch false;
            if (result) passed += 1 else failed += 1;
        }
    }

    if (opts.peek) return 0;
    return if (failed == 0) 0 else 1;
}

const Options = struct {
    verbose: bool = false,
    peek: bool = false,
};

fn parseArgs(gpa: std.mem.Allocator) !Options {
    var opts = Options{};
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    for (args[1..]) |arg| {
        var a = arg;
        if (std.mem.startsWith(u8, a, "ARGS=")) {
            a = a["ARGS=".len..];
            if (a.len == 0) continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("Usage: smoke [--verbose] [--peek]\n", .{});
            return error.ShowHelp;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--peek")) {
            opts.peek = true;
        } else {
            return error.UnknownArg;
        }
    }
    return opts;
}

fn runVariantThread(gpa: std.mem.Allocator, opts: Options, boards: []const config_mod.Board, variant: config_mod.Variant, timeout: u32, result: *?bool) void {
    result.* = runVariant(gpa, opts, boards, variant, timeout) catch false;
}

fn runVariant(gpa: std.mem.Allocator, opts: Options, boards: []const config_mod.Board, variant: config_mod.Variant, timeout_secs: u32) !bool {
    const board = config_mod.findBoard(boards, variant.board, variant.arch) orelse return error.UnknownBoard;
    const qemu = board.qemu orelse return error.UnsupportedBoard;
    const opt_tag = normalizeOptimize(variant.optimize) orelse return error.UnknownOptimize;

    const name = try std.fmt.allocPrint(gpa, "{s}-{s}-{s}", .{ variant.arch, variant.board, opt_tag });
    const log_path = try std.fmt.allocPrint(gpa, "zig-out/tests/{s}.log", .{name});
    const ext = if (std.mem.eql(u8, board.boot_image, "elf")) "elf" else "bin";
    const kernel_path = try std.fmt.allocPrint(gpa, "zig-out/kernel/{s}.{s}", .{ name, ext });

    std.fs.cwd().access(kernel_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{s}: FAIL (missing artifact)\n", .{name});
            return false;
        }
        return err;
    };

    var log_file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer log_file.close();
    var log_buf: [8192]u8 = undefined;
    var log_writer = log_file.writer(&log_buf);
    defer log_writer.interface.flush() catch {};

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, qemu.system);
    try argv.append(gpa, "-machine");
    try argv.append(gpa, qemu.machine);
    if (qemu.cpu) |cpu| {
        try argv.append(gpa, "-cpu");
        try argv.append(gpa, cpu);
    }
    try argv.appendSlice(gpa, qemu.args);
    try argv.append(gpa, "-nographic");
    try argv.append(gpa, "-kernel");
    try argv.append(gpa, kernel_path);

    if (opts.verbose) std.debug.print("{s}: running {s}\n", .{ name, argv.items[0] });

    var proc = std.process.Child.init(argv.items, gpa);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    try proc.spawn();

    const Streams = enum { stdout, stderr };
    var poller = std.io.poll(gpa, Streams, .{ .stdout = proc.stdout.?, .stderr = proc.stderr.? });
    defer poller.deinit();

    const timeout: u32 = if (opts.peek) PEEK_TIMEOUT else timeout_secs;
    const start_ns: i128 = std.time.nanoTimestamp();
    const deadline: i128 = start_ns + @as(i128, timeout) * std.time.ns_per_s;

    var stdout_written: usize = 0;
    var stderr_written: usize = 0;

    while (std.time.nanoTimestamp() < deadline) {
        _ = try poller.pollTimeout(10 * std.time.ns_per_ms);
        flushToLog(poller.reader(.stdout), &stdout_written, &log_writer.interface);
        flushToLog(poller.reader(.stderr), &stderr_written, &log_writer.interface);
        trimBuffer(poller.reader(.stdout), &stdout_written, 16 * 1024);
        trimBuffer(poller.reader(.stderr), &stderr_written, 16 * 1024);

        if (opts.peek) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        const out = poller.reader(.stdout).buffered();
        const err_out = poller.reader(.stderr).buffered();
        if (std.mem.indexOf(u8, out, BOOT_OK) != null or std.mem.indexOf(u8, err_out, BOOT_OK) != null) {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            std.debug.print("{s}: PASS\n", .{name});
            return true;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    _ = proc.kill() catch {};
    _ = proc.wait() catch {};

    const output = joinBuffers(gpa, poller.reader(.stdout).buffered(), poller.reader(.stderr).buffered());
    defer if (output.owned) gpa.free(output.buf);
    const filtered = filterNoise(output.buf, variant.arch);

    if (opts.peek) {
        printBlock(name, "peek", filtered);
        return true;
    }

    printBlock(name, "timeout", filtered);
    return false;
}

fn normalizeOptimize(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "debug")) return "debug";
    if (std.ascii.eqlIgnoreCase(name, "release") or
        std.ascii.eqlIgnoreCase(name, "releasefast") or
        std.ascii.eqlIgnoreCase(name, "releasesafe") or
        std.ascii.eqlIgnoreCase(name, "releasesmall")) return "release";
    return null;
}

fn printBlock(name: []const u8, status: []const u8, output: []const u8) void {
    std.debug.print("\n---- {s}: {s} ----\n", .{ name, status });

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trimRight(u8, line, "\r");
        if (clean.len == 0) {
            std.debug.print("\n", .{});
        } else {
            std.debug.print("{s}\n", .{clean});
        }
    }
    std.debug.print("---- end ----\n", .{});
}

fn filterNoise(output: []const u8, arch: []const u8) []const u8 {
    if (!std.mem.eql(u8, arch, "riscv64")) return output;
    if (std.mem.indexOf(u8, output, "Bullfinch")) |i| {
        const start = std.mem.lastIndexOfScalar(u8, output[0..i], '\n') orelse i;
        return output[start..];
    }
    if (std.mem.indexOf(u8, output, BOOT_OK)) |i| {
        const start = std.mem.lastIndexOfScalar(u8, output[0..i], '\n') orelse i;
        return output[start..];
    }
    return output;
}

fn flushToLog(reader: *std.io.Reader, written: *usize, writer: *std.Io.Writer) void {
    const buf = reader.buffered();
    if (written.* < buf.len) {
        writer.writeAll(buf[written.*..]) catch {};
        written.* = buf.len;
    }
}

fn trimBuffer(reader: *std.io.Reader, written: *usize, keep: usize) void {
    const len = reader.bufferedLen();
    if (len <= keep) return;
    const drop = len - keep;
    _ = reader.discard(std.io.Limit.limited(drop)) catch {};
    written.* = if (written.* >= drop) written.* - drop else 0;
}

fn joinBuffers(gpa: std.mem.Allocator, a: []const u8, b: []const u8) struct { buf: []const u8, owned: bool } {
    if (b.len == 0) return .{ .buf = a, .owned = false };
    var out = gpa.alloc(u8, a.len + b.len) catch return .{ .buf = a, .owned = false };
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return .{ .buf = out, .owned = true };
}
