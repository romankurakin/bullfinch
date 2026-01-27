//! Board definitions for build and test tooling.

const std = @import("std");

pub const Arch = enum {
    arm64,
    riscv64,
};

pub const Board = struct {
    name: []const u8,
    arch: Arch,
    boot_image: BootImage,
    board_zig: []const u8,
    linker_script: []const u8,
    qemu: ?Qemu,
};

pub const BootImage = enum {
    elf,
    bin,
};

pub const Qemu = struct {
    system: []const u8,
    machine: []const u8,
    args: []const []const u8,
    cpu: ?[]const u8,
};

pub const boards = [_]Board{
    .{
        .name = "qemu_virt",
        .arch = .arm64,
        .boot_image = .bin,
        .board_zig = "src/kernel/arch/arm64/boards/qemu_virt/board.zig",
        .linker_script = "src/kernel/arch/arm64/boards/qemu_virt/kernel.ld",
        .qemu = .{
            .system = "qemu-system-aarch64",
            .machine = "virt,gic-version=3",
            .args = &.{ "-smp", "2", "-m", "2G" },
            .cpu = "cortex-a76",
        },
    },
    .{
        .name = "qemu_virt",
        .arch = .riscv64,
        .boot_image = .elf,
        .board_zig = "src/kernel/arch/riscv64/boards/qemu_virt/board.zig",
        .linker_script = "src/kernel/arch/riscv64/boards/qemu_virt/kernel.ld",
        .qemu = .{
            .system = "qemu-system-riscv64",
            .machine = "virt",
            .args = &.{ "-smp", "2", "-m", "2G", "-bios", "default" },
            .cpu = null,
        },
    },
};

pub fn find(name: []const u8, arch: Arch) ?Board {
    for (boards) |board| {
        if (board.arch == arch and std.mem.eql(u8, board.name, name)) {
            return board;
        }
    }
    return null;
}

pub fn list() []const Board {
    return &boards;
}

pub fn archTag(arch: Arch) []const u8 {
    return switch (arch) {
        .arm64 => "arm64",
        .riscv64 => "riscv64",
    };
}

pub fn parseArch(name: []const u8) ?Arch {
    if (std.ascii.eqlIgnoreCase(name, "arm64")) return .arm64;
    if (std.ascii.eqlIgnoreCase(name, "aarch64")) return .arm64;
    if (std.ascii.eqlIgnoreCase(name, "riscv64")) return .riscv64;
    return null;
}
