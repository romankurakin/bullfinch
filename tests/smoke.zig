//! Smoke Test Runner.
//!
//! Runs pre-built kernels in QEMU, checks for success marker.
//! Build kernels first with: just build-arm64 build-riscv64

const std = @import("std");
const boards = @import("boards");

const BOOT_OK = "[BOOT:OK]";
const DEFAULT_CONFIG_PATH = "tests/config.json";
const DEFAULT_REPORT_PATH = "zig-out/tests/smoke-results.json";
const DEFAULT_PEEK_SECS: u32 = 2;

const Variant = struct {
    board: []const u8,
    arch: []const u8,
    optimize: []const u8,
};

const Config = struct {
    variants: []Variant,
    timeout_secs: u32 = 15,
    parallel: bool = true,
};

const Options = struct {
    config_path: []const u8,
    report_path: []const u8,
    verbose: bool,
    peek: bool,
};

const Result = struct {
    name: []const u8,
    board: []const u8,
    arch: []const u8,
    optimize: []const u8,
    passed: bool,
    reason: []const u8,
    duration_ms: u64,
    log_path: []const u8,
};

const RunResult = struct {
    result: Result,
    err: ?anyerror,
};

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

    const config_data = try std.fs.cwd().readFileAlloc(gpa, opts.config_path, 1024 * 1024);
    defer gpa.free(config_data);

    const parsed = try std.json.parseFromSlice(Config, gpa, config_data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const config = parsed.value;

    try std.fs.cwd().makePath("zig-out/tests");

    var results = try gpa.alloc(Result, config.variants.len);
    var run_results = try gpa.alloc(RunResult, config.variants.len);
    defer gpa.free(results);
    defer gpa.free(run_results);

    var had_internal_error = false;

    if (config.parallel and !opts.peek and config.variants.len > 1) {
        var threads = try gpa.alloc(std.Thread, config.variants.len);
        defer gpa.free(threads);

        var contexts = try gpa.alloc(RunContext, config.variants.len);
        defer gpa.free(contexts);

        for (config.variants, 0..) |variant, idx| {
            contexts[idx] = .{
                .allocator = gpa,
                .options = opts,
                .variant = variant,
                .timeout_secs = config.timeout_secs,
                .run_result = &run_results[idx],
            };
            threads[idx] = try std.Thread.spawn(.{}, runVariantThread, .{&contexts[idx]});
        }

        for (threads) |t| t.join();
    } else {
        for (config.variants, 0..) |variant, idx| {
            run_results[idx] = .{
                .result = resultFor(variant, "unknown", "unknown", 0, "zig-out/tests/unknown.log"),
                .err = null,
            };
            var ctx = RunContext{
                .allocator = gpa,
                .options = opts,
                .variant = variant,
                .timeout_secs = config.timeout_secs,
                .run_result = &run_results[idx],
            };
            runVariantThread(&ctx);
        }
    }

    for (run_results, 0..) |entry, idx| {
        results[idx] = entry.result;
        if (entry.err != null) had_internal_error = true;
    }

    try writeReport(opts, results, opts.peek);

    if (had_internal_error) return 2;
    if (opts.peek) return 0;

    const all_passed = for (results) |r| {
        if (!r.passed) break false;
    } else true;
    return if (all_passed) 0 else 1;
}

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var opts = Options{
        .config_path = DEFAULT_CONFIG_PATH,
        .report_path = DEFAULT_REPORT_PATH,
        .verbose = false,
        .peek = false,
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var arg = args[i];
        if (std.mem.startsWith(u8, arg, "ARGS=")) {
            arg = arg["ARGS=".len..];
            if (arg.len == 0) continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return error.ShowHelp;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--peek")) {
            opts.peek = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            opts.config_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            opts.report_path = try allocator.dupe(u8, args[i]);
        } else {
            return error.UnknownArg;
        }
    }

    return opts;
}

fn printUsage() !void {
    var buffer: [256]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer = stdout_file.writer(&buffer);
    try writer.interface.writeAll(
        "Usage: smoke [--config path] [--output path] [--verbose] [--peek]\n",
    );
    try writer.interface.flush();
}

const RunContext = struct {
    allocator: std.mem.Allocator,
    options: Options,
    variant: Variant,
    timeout_secs: u32,
    run_result: *RunResult,
};

fn runVariantThread(ctx: *RunContext) void {
    const result = runVariant(ctx.allocator, ctx.options, ctx.variant, ctx.timeout_secs) catch |err| {
        ctx.run_result.* = .{
            .result = resultFor(ctx.variant, "unknown", "internal-error", 0, "zig-out/tests/unknown.log"),
            .err = err,
        };
        return;
    };
    ctx.run_result.* = .{ .result = result, .err = null };
}

fn runVariant(
    allocator: std.mem.Allocator,
    opts: Options,
    variant: Variant,
    timeout_secs: u32,
) !Result {
    const arch = boards.parseArch(variant.arch) orelse return error.UnknownArch;
    const board_info = boards.find(variant.board, arch) orelse return error.UnknownBoard;
    const qemu = board_info.qemu orelse return error.UnsupportedBoard;
    const optimize_tag = normalizeOptimizeTag(variant.optimize) orelse return error.UnknownOptimize;

    const base_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
        boards.archTag(arch),
        variant.board,
        optimize_tag,
    });
    const log_path = try std.fmt.allocPrint(allocator, "zig-out/tests/{s}.log", .{base_name});
    const kernel_ext = switch (board_info.boot_image) {
        .elf => "elf",
        .bin => "bin",
    };
    const kernel_path = try std.fmt.allocPrint(allocator, "zig-out/kernel/{s}.{s}", .{ base_name, kernel_ext });

    const exists = std.fs.cwd().access(kernel_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const result = resultFor(variant, base_name, "missing-artifact", 0, log_path);
            std.debug.print("{s}: FAIL (missing artifact)\n", .{base_name});
            return result;
        }
        return err;
    };
    _ = exists;

    var log_file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer log_file.close();
    var log_buffer: [8192]u8 = undefined;
    var log_writer = log_file.writer(&log_buffer);
    defer log_writer.interface.flush() catch {};

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, qemu.system);
    try argv.append(allocator, "-machine");
    try argv.append(allocator, qemu.machine);
    if (qemu.cpu) |cpu| {
        try argv.append(allocator, "-cpu");
        try argv.append(allocator, cpu);
    }
    try argv.appendSlice(allocator, qemu.args);
    try argv.append(allocator, "-nographic");
    try argv.append(allocator, "-kernel");
    try argv.append(allocator, kernel_path);

    if (opts.verbose) {
        std.debug.print("{s}: running {s}\n", .{ base_name, argv.items[0] });
    }

    var qemu_proc = std.process.Child.init(argv.items, allocator);
    qemu_proc.stdout_behavior = .Pipe;
    qemu_proc.stderr_behavior = .Pipe;
    try qemu_proc.spawn();

    const stdout = qemu_proc.stdout.?;
    const stderr = qemu_proc.stderr.?;
    const Streams = enum { stdout, stderr };
    var poller = std.io.poll(allocator, Streams, .{ .stdout = stdout, .stderr = stderr });
    defer poller.deinit();

    const max_keep: usize = 16 * 1024;
    const timeout = if (opts.peek) DEFAULT_PEEK_SECS else timeout_secs;
    const start_ns: i128 = std.time.nanoTimestamp();
    const deadline: i128 = start_ns + @as(i128, timeout) * std.time.ns_per_s;

    var stdout_written: usize = 0;
    var stderr_written: usize = 0;

    while (std.time.nanoTimestamp() < deadline) {
        _ = try poller.pollTimeout(10 * std.time.ns_per_ms);

        writeNewOutput(poller.reader(.stdout), &stdout_written, &log_writer.interface);
        writeNewOutput(poller.reader(.stderr), &stderr_written, &log_writer.interface);
        trimReader(poller.reader(.stdout), &stdout_written, max_keep);
        trimReader(poller.reader(.stderr), &stderr_written, max_keep);

        if (opts.peek) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        const out_stdout = poller.reader(.stdout).buffered();
        const out_stderr = poller.reader(.stderr).buffered();
        const saw_ok = std.mem.indexOf(u8, out_stdout, BOOT_OK) != null or
            std.mem.indexOf(u8, out_stderr, BOOT_OK) != null;
        if (saw_ok) {
            _ = qemu_proc.kill() catch {};
            _ = qemu_proc.wait() catch {};
            const duration_ms = durationMs(start_ns, std.time.nanoTimestamp());
            std.debug.print("{s}: PASS\n", .{base_name});
            return resultFor(variant, base_name, "ok", duration_ms, log_path);
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    _ = qemu_proc.kill() catch {};
    _ = qemu_proc.wait() catch {};
    const duration_ms = durationMs(start_ns, std.time.nanoTimestamp());
    if (opts.peek) {
        const out_stdout = poller.reader(.stdout).buffered();
        const out_stderr = poller.reader(.stderr).buffered();
        const out = joinOutput(out_stdout, out_stderr);
        defer if (out.owned) allocator.free(out.buf);
        const filtered = filterOutput(out.buf, variant.arch);
        printBlock(base_name, "peek", filtered);
        return resultFor(variant, base_name, "peek", duration_ms, log_path);
    }

    const out_stdout = poller.reader(.stdout).buffered();
    const out_stderr = poller.reader(.stderr).buffered();
    const out = joinOutput(out_stdout, out_stderr);
    defer if (out.owned) allocator.free(out.buf);
    const filtered = filterOutput(out.buf, variant.arch);
    printBlock(base_name, "timeout", filtered);
    return resultFor(variant, base_name, "timeout", duration_ms, log_path);
}

fn normalizeOptimizeTag(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "debug")) return "debug";
    if (std.ascii.eqlIgnoreCase(name, "release")) return "release";
    if (std.ascii.eqlIgnoreCase(name, "releasefast")) return "release";
    if (std.ascii.eqlIgnoreCase(name, "releasesafe")) return "release";
    if (std.ascii.eqlIgnoreCase(name, "releasesmall")) return "release";
    return null;
}

fn filterOutput(output: []const u8, arch: []const u8) []const u8 {
    if (!std.ascii.eqlIgnoreCase(arch, "riscv64")) return output;
    if (std.mem.indexOf(u8, output, "Bullfinch")) |idx| return output[idx..];
    if (std.mem.indexOf(u8, output, "[BOOT:OK]")) |idx| return output[idx..];
    return output;
}

fn printBlock(name: []const u8, status: []const u8, output: []const u8) void {
    std.debug.print("\n---- {s}: {s} ----\n", .{ name, status });
    if (output.len != 0) {
        std.debug.print("{s}", .{output});
        if (output[output.len - 1] != '\n') std.debug.print("\n", .{});
    }
    std.debug.print("---- end ----\n", .{});
}

fn durationMs(start_ns: i128, end_ns: i128) u64 {
    if (end_ns <= start_ns) return 0;
    const delta = end_ns - start_ns;
    return @as(u64, @intCast(@divTrunc(delta, std.time.ns_per_ms)));
}

fn resultFor(
    variant: Variant,
    name: []const u8,
    reason: []const u8,
    duration_ms: u64,
    log_path: []const u8,
) Result {
    return .{
        .name = name,
        .board = variant.board,
        .arch = variant.arch,
        .optimize = variant.optimize,
        .passed = std.mem.eql(u8, reason, "ok") or std.mem.eql(u8, reason, "peek"),
        .reason = reason,
        .duration_ms = duration_ms,
        .log_path = log_path,
    };
}

fn writeReport(opts: Options, results: []const Result, peek: bool) !void {
    var report_file = try std.fs.cwd().createFile(opts.report_path, .{ .truncate = true });
    defer report_file.close();
    var report_buffer: [4096]u8 = undefined;
    var writer = report_file.writer(&report_buffer);

    const Report = struct {
        mode: []const u8,
        all_passed: bool,
        results: []const Result,
    };

    const all_passed = for (results) |r| {
        if (!r.passed) break false;
    } else true;

    const report = Report{
        .mode = if (peek) "peek" else "smoke",
        .all_passed = all_passed,
        .results = results,
    };

    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn writeNewOutput(reader: *std.io.Reader, written: *usize, writer: *std.Io.Writer) void {
    const buf = reader.buffered();
    if (written.* < buf.len) {
        const new = buf[written.*..];
        writer.writeAll(new) catch {};
        written.* = buf.len;
    }
}

fn trimReader(reader: *std.io.Reader, written: *usize, keep: usize) void {
    const len = reader.bufferedLen();
    if (len <= keep) return;
    const drop = len - keep;
    _ = reader.discard(std.io.Limit.limited(drop)) catch {};
    if (written.* >= drop) {
        written.* -= drop;
    } else {
        written.* = 0;
    }
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
