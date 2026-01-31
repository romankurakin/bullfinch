//! Shared configuration types and utilities.
//!

const std = @import("std");

pub const CONFIG_PATH = "infra/config.json";

pub const Board = struct {
    name: []const u8,
    arch: []const u8,
    boot_image: []const u8,
    board_zig: []const u8,
    linker_script: []const u8,
    qemu: ?Qemu,
};

pub const Qemu = struct {
    system: []const u8,
    machine: []const u8,
    cpu: ?[]const u8,
    args: []const []const u8,
};

pub const SmokeConfig = struct {
    timeout_secs: u32 = 15,
    parallel: bool = true,
    variants: []const Variant,
};

pub const Variant = struct {
    board: []const u8,
    arch: []const u8,
    optimize: []const u8,
};

pub const Config = struct {
    boards: []const Board,
    smoke: SmokeConfig,
};

pub fn parse(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    const data = try std.fs.cwd().readFileAlloc(allocator, CONFIG_PATH, 1024 * 1024);
    defer allocator.free(data);
    return std.json.parseFromSlice(Config, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn findBoard(boards: []const Board, name: []const u8, arch: []const u8) ?Board {
    for (boards) |board| {
        if (std.mem.eql(u8, board.name, name) and std.mem.eql(u8, board.arch, arch)) {
            return board;
        }
    }
    return null;
}
