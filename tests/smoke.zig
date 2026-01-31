//! Smoke Test Runner.
//!
//! Runs pre-built kernels in QEMU, checks for success marker.
//! Symbolizes backtrace addresses in peek output.

const std = @import("std");
const boards = @import("boards");

const BOOT_OK = "[BOOT:OK]";
const CONFIG_PATH = "tests/config.json";
const REPORT_PATH = "zig-out/tests/smoke-results.json";
const PEEK_TIMEOUT: u32 = 4;
const SMOKE_TIMEOUT: u32 = 15;

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

    const parsed = try std.json.parseFromSlice(Config, gpa, config_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const config = parsed.value;

    try std.fs.cwd().makePath("zig-out/tests");

    var results = try gpa.alloc(Result, config.variants.len);
    var run_results = try gpa.alloc(RunResult, config.variants.len);
    defer gpa.free(results);
    defer gpa.free(run_results);

    var had_error = false;

    if (config.parallel and !opts.peek and config.variants.len > 1) {
        var threads = try gpa.alloc(std.Thread, config.variants.len);
        defer gpa.free(threads);
        var contexts = try gpa.alloc(RunContext, config.variants.len);
        defer gpa.free(contexts);

        for (config.variants, 0..) |variant, i| {
            contexts[i] = .{ .gpa = gpa, .opts = opts, .variant = variant, .timeout_secs = config.timeout_secs, .out = &run_results[i] };
            threads[i] = try std.Thread.spawn(.{}, runThread, .{&contexts[i]});
        }
        for (threads) |t| t.join();
    } else {
        for (config.variants, 0..) |variant, i| {
            run_results[i] = .{ .result = emptyResult(variant), .err = null };
            var ctx = RunContext{ .gpa = gpa, .opts = opts, .variant = variant, .timeout_secs = config.timeout_secs, .out = &run_results[i] };
            runThread(&ctx);
        }
    }

    for (run_results, 0..) |entry, i| {
        results[i] = entry.result;
        if (entry.err != null) had_error = true;
    }

    try writeReport(opts, results);

    if (had_error) return 2;
    if (opts.peek) return 0;

    const all_passed = for (results) |r| {
        if (!r.passed) break false;
    } else true;
    return if (all_passed) 0 else 1;
}

const Config = struct {
    variants: []Variant,
    timeout_secs: u32 = SMOKE_TIMEOUT,
    parallel: bool = true,
};

const Variant = struct {
    board: []const u8,
    arch: []const u8,
    optimize: []const u8,
};

const Options = struct {
    config_path: []const u8 = CONFIG_PATH,
    report_path: []const u8 = REPORT_PATH,
    verbose: bool = false,
    peek: bool = false,
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

const RunContext = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    variant: Variant,
    timeout_secs: u32,
    out: *RunResult,
};

fn parseArgs(gpa: std.mem.Allocator) !Options {
    var opts = Options{};
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var arg = args[i];
        if (std.mem.startsWith(u8, arg, "ARGS=")) {
            arg = arg["ARGS=".len..];
            if (arg.len == 0) continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: smoke [--config path] [--output path] [--verbose] [--peek]\n", .{});
            return error.ShowHelp;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--peek")) {
            opts.peek = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            opts.config_path = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            opts.report_path = try gpa.dupe(u8, args[i]);
        } else {
            return error.UnknownArg;
        }
    }
    return opts;
}

fn runThread(ctx: *RunContext) void {
    const result = runVariant(ctx.gpa, ctx.opts, ctx.variant, ctx.timeout_secs) catch |err| {
        ctx.out.* = .{ .result = emptyResult(ctx.variant), .err = err };
        return;
    };
    ctx.out.* = .{ .result = result, .err = null };
}

fn runVariant(gpa: std.mem.Allocator, opts: Options, variant: Variant, timeout_secs: u32) !Result {
    const arch = boards.parseArch(variant.arch) orelse return error.UnknownArch;
    const board_info = boards.find(variant.board, arch) orelse return error.UnknownBoard;
    const qemu = board_info.qemu orelse return error.UnsupportedBoard;
    const opt_tag = normalizeOptimize(variant.optimize) orelse return error.UnknownOptimize;

    const name = try std.fmt.allocPrint(gpa, "{s}-{s}-{s}", .{ boards.archTag(arch), variant.board, opt_tag });
    const log_path = try std.fmt.allocPrint(gpa, "zig-out/tests/{s}.log", .{name});
    const ext = if (board_info.boot_image == .elf) "elf" else "bin";
    const kernel_path = try std.fmt.allocPrint(gpa, "zig-out/kernel/{s}.{s}", .{ name, ext });

    std.fs.cwd().access(kernel_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("{s}: FAIL (missing artifact)\n", .{name});
            return makeResult(variant, name, "missing-artifact", 0, log_path);
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

    const timeout = if (opts.peek) PEEK_TIMEOUT else timeout_secs;
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
            return makeResult(variant, name, "ok", durationMs(start_ns), log_path);
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    _ = proc.kill() catch {};
    _ = proc.wait() catch {};

    const output = joinBuffers(gpa, poller.reader(.stdout).buffered(), poller.reader(.stderr).buffered());
    defer if (output.owned) gpa.free(output.buf);
    const filtered = filterRiscvNoise(output.buf, variant.arch);

    if (opts.peek) {
        printBlock(name, "peek", filtered);
        return makeResult(variant, name, "peek", durationMs(start_ns), log_path);
    }

    printBlock(name, "timeout", filtered);
    return makeResult(variant, name, "timeout", durationMs(start_ns), log_path);
}

fn printBlock(name: []const u8, status: []const u8, output: []const u8) void {
    const elf = elfPath(name);
    std.debug.print("\n---- {s}: {s} ----\n", .{ name, status });

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const clean = std.mem.trimRight(u8, line, "\r");
        if (clean.len == 0) {
            std.debug.print("\n", .{});
            continue;
        }
        if (elf != null and isBacktraceLine(clean)) {
            const trimmed = std.mem.trimRight(u8, clean, " \t");
            if (extractAddr(clean)) |addr| {
                const sym = symbolize(elf.?, addr);
                if (sym.len > 0) {
                    printBacktraceSymbol(trimmed, sym.slice());
                    continue;
                }
            }
            std.debug.print("{s}\n", .{trimmed});
        } else {
            std.debug.print("{s}\n", .{clean});
        }
    }
    std.debug.print("---- end ----\n", .{});
}

fn printBacktraceSymbol(line: []const u8, sym: []const u8) void {
    std.debug.print("{s}  {s}\n", .{ line, sym });
}

fn elfPath(name: []const u8) ?[]const u8 {
    const is_arm = std.mem.indexOf(u8, name, "arm64") != null;
    const is_riscv = std.mem.indexOf(u8, name, "riscv64") != null;
    const is_release = std.mem.indexOf(u8, name, "release") != null;
    if (is_arm) return if (is_release) "zig-out/kernel/arm64-qemu_virt-release.elf" else "zig-out/kernel/arm64-qemu_virt-debug.elf";
    if (is_riscv) return if (is_release) "zig-out/kernel/riscv64-qemu_virt-release.elf" else "zig-out/kernel/riscv64-qemu_virt-debug.elf";
    return null;
}

fn isBacktraceLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len or line[i] != '#') return false;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i + 2 <= line.len and line[i] == '0' and line[i + 1] == 'x';
}

fn extractAddr(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, "0x") orelse return null;
    var end = start + 2;
    while (end < line.len and std.ascii.isHex(line[end])) : (end += 1) {}
    return line[start..end];
}

const SymbolResult = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const SymbolResult) []const u8 {
        return self.buf[0..self.len];
    }
};

fn symbolize(elf: []const u8, addr: []const u8) SymbolResult {
    var sym = SymbolResult{};
    const gpa = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{ "llvm-symbolizer", "-e", elf, "-f", addr },
        .max_output_bytes = 256,
    }) catch return sym;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.stdout.len == 0) return sym;
    const newline = std.mem.indexOf(u8, result.stdout, "\n") orelse result.stdout.len;
    const func = result.stdout[0..newline];
    if (std.mem.eql(u8, func, "??")) return sym;

    sym.len = @min(func.len, sym.buf.len);
    @memcpy(sym.buf[0..sym.len], func[0..sym.len]);
    return sym;
}

fn writeReport(opts: Options, results: []const Result) !void {
    var file = try std.fs.cwd().createFile(opts.report_path, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);

    const all_passed = for (results) |r| {
        if (!r.passed) break false;
    } else true;

    const Report = struct { mode: []const u8, all_passed: bool, results: []const Result };
    try std.json.Stringify.value(
        Report{ .mode = if (opts.peek) "peek" else "smoke", .all_passed = all_passed, .results = results },
        .{ .whitespace = .indent_2 },
        &writer.interface,
    );
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

fn normalizeOptimize(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "debug")) return "debug";
    if (std.ascii.eqlIgnoreCase(name, "release") or
        std.ascii.eqlIgnoreCase(name, "releasefast") or
        std.ascii.eqlIgnoreCase(name, "releasesafe") or
        std.ascii.eqlIgnoreCase(name, "releasesmall")) return "release";
    return null;
}

fn filterRiscvNoise(output: []const u8, arch: []const u8) []const u8 {
    if (!std.ascii.eqlIgnoreCase(arch, "riscv64")) return output;
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

fn makeResult(v: Variant, name: []const u8, reason: []const u8, ms: u64, log: []const u8) Result {
    return .{
        .name = name,
        .board = v.board,
        .arch = v.arch,
        .optimize = v.optimize,
        .passed = std.mem.eql(u8, reason, "ok") or std.mem.eql(u8, reason, "peek"),
        .reason = reason,
        .duration_ms = ms,
        .log_path = log,
    };
}

fn emptyResult(v: Variant) Result {
    return makeResult(v, "unknown", "internal-error", 0, "zig-out/tests/unknown.log");
}

fn durationMs(start_ns: i128) u64 {
    const delta = std.time.nanoTimestamp() - start_ns;
    return if (delta > 0) @intCast(@divTrunc(delta, std.time.ns_per_ms)) else 0;
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
