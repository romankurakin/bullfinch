//! Hardware Information.
//!
//! Captures hardware configuration from DTB at boot. Parsed once in virtInit(),
//! then accessed by PMM, interrupt controller, and other subsystems without
//! re-parsing the flat device tree.
//!
//! Uses static arrays to avoid chicken-egg with PMM allocation.

const std = @import("std");
const fdt = @import("../fdt/fdt.zig");
const limits = @import("../limits.zig");

const MAX_MEMORY_REGIONS = limits.MAX_MEMORY_ARENAS;
const MAX_RESERVED_REGIONS = limits.MAX_RESERVED_REGIONS;

pub const Region = fdt.Region;

/// ARM64-specific features.
pub const Arm64Features = struct {
    /// GIC info (version=0 means not present).
    gic: GicInfo = .{},
};

/// RISC-V-specific features.
pub const RiscvFeatures = struct {
    /// Zkr extension availability from DTB.
    has_zkr: bool = false,
};

/// Architecture feature bundles.
pub const Features = struct {
    arm64: Arm64Features = .{},
    riscv: RiscvFeatures = .{},
};

/// GIC interrupt controller info (ARM64 only).
pub const GicInfo = struct {
    version: u8 = 0, // 0 = not present, 2 or 3 = GIC version
    gicd_base: u64 = 0,
    gicc_base: u64 = 0, // GICv2 only
    gicr_base: u64 = 0, // GICv3 only
};

/// Hardware information discovered from DTB.
/// Populated once at boot, read-only thereafter.
pub const HardwareInfo = struct {
    /// DTB blob physical location. Used by kernel to create VMO;
    /// userspace receives handle to VMO, never raw physical address.
    dtb_phys: u64 = 0,
    dtb_size: u32 = 0,

    /// Memory regions from DTB, sorted by size descending.
    memory_regions: [MAX_MEMORY_REGIONS]Region = [_]Region{.{}} ** MAX_MEMORY_REGIONS,
    memory_region_count: u8 = 0,

    /// Total memory across all regions (cached sum).
    total_memory: u64 = 0,

    /// Reserved memory regions from DTB.
    reserved_regions: [MAX_RESERVED_REGIONS]Region = [_]Region{.{}} ** MAX_RESERVED_REGIONS,
    reserved_region_count: u8 = 0,

    /// Timer frequency in Hz.
    /// ARM64: set from CNTFRQ_EL0 register (DTB value ignored).
    /// RISC-V: from /cpus/timebase-frequency in DTB.
    timer_frequency: u64 = 0,

    /// CPU count from /cpus node.
    cpu_count: u32 = 0,

    /// UART base address discovered from DTB.
    uart_base: u64 = 0,

    /// Architecture-specific features from DTB.
    features: Features = .{},

    /// Slice of valid memory regions.
    pub fn memoryRegions(self: *const HardwareInfo) []const Region {
        return self.memory_regions[0..self.memory_region_count];
    }

    /// Slice of valid reserved regions.
    pub fn reservedRegions(self: *const HardwareInfo) []const Region {
        return self.reserved_regions[0..self.reserved_region_count];
    }
};

/// Global hardware info, populated by init().
pub var info: HardwareInfo = .{};

/// Initialize hardware info from DTB.
/// Must be called early in virtInit(), before PMM and other DTB consumers.
pub fn init(dtb_phys: usize, dtb_handle: fdt.Fdt) void {
    info.dtb_phys = dtb_phys;
    info.dtb_size = fdt.getTotalSize(dtb_handle);

    var mem_iter = fdt.getMemoryRegions(dtb_handle);
    while (mem_iter.next()) |region| {
        if (info.memory_region_count >= MAX_MEMORY_REGIONS) break;
        info.memory_regions[info.memory_region_count] = .{
            .base = region.base,
            .size = region.size,
        };
        info.memory_region_count += 1;
        info.total_memory += region.size;
    }

    sortRegionsBySize(info.memory_regions[0..info.memory_region_count]);

    var reserved_iter = fdt.getReservedRegions(dtb_handle);
    while (reserved_iter.next()) |region| {
        if (info.reserved_region_count >= MAX_RESERVED_REGIONS) break;
        info.reserved_regions[info.reserved_region_count] = .{
            .base = region.base,
            .size = region.size,
        };
        info.reserved_region_count += 1;
    }

    info.timer_frequency = getTimerFrequency(dtb_handle) orelse 0;
    info.cpu_count = getCpuCount(dtb_handle);
    info.features.riscv.has_zkr = getRiscvHasZkr(dtb_handle);
    info.features.arm64.gic = getGicInfo(dtb_handle);
    info.uart_base = getUartBase(dtb_handle) orelse 0;
}

/// Sort regions by size descending (simple insertion sort, N is small).
fn sortRegionsBySize(regions: []Region) void {
    if (regions.len <= 1) return;
    for (1..regions.len) |i| {
        const key = regions[i];
        var j: usize = i;
        while (j > 0 and regions[j - 1].size < key.size) : (j -= 1) {
            regions[j] = regions[j - 1];
        }
        regions[j] = key;
    }
}

/// Get timer frequency from /cpus/timebase-frequency (RISC-V).
/// ARM64 ignores this and reads CNTFRQ_EL0 register directly.
fn getTimerFrequency(dtb: fdt.Fdt) ?u64 {
    const cpus = fdt.pathOffset(dtb, "/cpus") orelse return null;
    const prop = fdt.getprop(dtb, cpus, "timebase-frequency") orelse return null;
    if (prop.len < 4) return null;
    return std.mem.readInt(u32, prop[0..4], .big);
}

/// Count CPU nodes under /cpus (nodes starting with "cpu@").
fn getCpuCount(dtb: fdt.Fdt) u32 {
    const cpus = fdt.pathOffset(dtb, "/cpus") orelse return 0;
    var count: u32 = 0;
    var node = fdt.firstSubnode(dtb, cpus);
    while (node) |offset| {
        const name = fdt.getName(dtb, offset) orelse "";
        if (std.mem.startsWith(u8, name, "cpu@")) count += 1;
        node = fdt.nextSubnode(dtb, offset);
    }
    return count;
}

/// Find the first CPU node under /cpus.
fn firstCpuNode(dtb: fdt.Fdt) ?i32 {
    const cpus = fdt.pathOffset(dtb, "/cpus") orelse return null;
    var node = fdt.firstSubnode(dtb, cpus);
    while (node) |offset| {
        const name = fdt.getName(dtb, offset) orelse "";
        if (std.mem.startsWith(u8, name, "cpu@")) return offset;
        node = fdt.nextSubnode(dtb, offset);
    }
    return null;
}

/// Check for a string entry in a NUL-separated string list property.
fn hasStringListEntry(prop: []const u8, entry: []const u8) bool {
    var i: usize = 0;
    while (i < prop.len) {
        const start = i;
        while (i < prop.len and prop[i] != 0) : (i += 1) {}
        const item = prop[start..i];
        if (item.len != 0 and std.mem.eql(u8, item, entry)) return true;
        if (i < prop.len) i += 1; // skip NUL
    }
    return false;
}

/// Convert a DTB string property to a slice without trailing NULs.
fn trimPropString(prop: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, prop, 0)) |nul| return prop[0..nul];
    return prop;
}

/// Check for an underscore-delimited extension in a riscv,isa string.
fn isaStringHasExtension(isa: []const u8, ext: []const u8) bool {
    if (ext.len == 0 or isa.len < ext.len) return false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, isa, pos, ext)) |idx| {
        const before_ok = idx == 0 or isa[idx - 1] == '_';
        const after = idx + ext.len;
        const after_ok = after == isa.len or isa[after] == '_';
        if (before_ok and after_ok) return true;
        pos = idx + 1;
    }
    return false;
}

/// Detect RISC-V Zkr support from DTB ISA properties.
/// Checks riscv,isa-extensions first, then falls back to deprecated riscv,isa.
fn getRiscvHasZkr(dtb: fdt.Fdt) bool {
    const cpu = firstCpuNode(dtb) orelse return false;

    if (fdt.getprop(dtb, cpu, "riscv,isa-extensions")) |prop| {
        if (hasStringListEntry(prop, "zkr")) return true;
    }

    if (fdt.getprop(dtb, cpu, "riscv,isa")) |prop| {
        const isa = trimPropString(prop);
        return isaStringHasExtension(isa, "zkr");
    }

    return false;
}

/// Parse GIC info from DTB (ARM64 only).
fn getGicInfo(dtb: fdt.Fdt) GicInfo {
    if (fdt.findByCompatible(dtb, "arm,gic-v3")) |node| {
        if (parseGicRegs(dtb, node, 3)) |gic| return gic;
    }
    // QEMU uses cortex-a15-gic, real hardware often uses gic-400
    if (fdt.findByCompatible(dtb, "arm,cortex-a15-gic")) |node| {
        if (parseGicRegs(dtb, node, 2)) |gic| return gic;
    }
    if (fdt.findByCompatible(dtb, "arm,gic-400")) |node| {
        if (parseGicRegs(dtb, node, 2)) |gic| return gic;
    }
    return .{}; // Not found (RISC-V or no GIC)
}

/// Parse GIC reg property into base addresses.
fn parseGicRegs(dtb: fdt.Fdt, node: i32, version: u8) ?GicInfo {
    const reg = fdt.getprop(dtb, node, "reg") orelse return null;
    // GIC typically uses 2 address cells, 2 size cells
    const cells = fdt.CellSizes{ .addr_cells = 2, .size_cells = 2 };

    const region0 = fdt.parseRegEntry(reg, 0, cells) orelse return null;
    const region1 = fdt.parseRegEntry(reg, cells.entrySize(), cells);

    return switch (version) {
        3 => .{
            .version = 3,
            .gicd_base = region0.base,
            .gicr_base = if (region1) |r| r.base else 0,
        },
        2 => .{
            .version = 2,
            .gicd_base = region0.base,
            .gicc_base = if (region1) |r| r.base else 0,
        },
        else => null,
    };
}

/// Find UART base address from DTB.
/// Searches for arm,pl011 (ARM) or ns16550a (RISC-V QEMU).
fn getUartBase(dtb: fdt.Fdt) ?u64 {
    if (fdt.findByCompatible(dtb, "arm,pl011")) |node| {
        if (parseDeviceBase(dtb, node)) |base| return base;
    }
    if (fdt.findByCompatible(dtb, "ns16550a")) |node| {
        if (parseDeviceBase(dtb, node)) |base| return base;
    }
    return null;
}

/// Parse first reg entry to get device base address.
fn parseDeviceBase(dtb: fdt.Fdt, node: i32) ?u64 {
    const reg = fdt.getprop(dtb, node, "reg") orelse return null;
    // Most devices use 2 address cells, 2 size cells
    const cells = fdt.CellSizes{ .addr_cells = 2, .size_cells = 2 };
    const region = fdt.parseRegEntry(reg, 0, cells) orelse return null;
    return region.base;
}

comptime {
    std.debug.assert(@sizeOf(Region) == 16);
    std.debug.assert(@sizeOf(GicInfo) <= 32);
    std.debug.assert(@sizeOf(HardwareInfo) <= 512);
}

const testing = std.testing;

test "defaults GicInfo to not present" {
    const gic = GicInfo{};
    try testing.expectEqual(@as(u8, 0), gic.version);
    try testing.expectEqual(@as(u64, 0), gic.gicd_base);
}

test "distinguishes GIC versions via GicInfo.version" {
    const v2 = GicInfo{ .version = 2, .gicd_base = 0x8000000, .gicc_base = 0x8010000 };
    const v3 = GicInfo{ .version = 3, .gicd_base = 0x8000000, .gicr_base = 0x80A0000 };

    try testing.expectEqual(@as(u8, 2), v2.version);
    try testing.expectEqual(@as(u8, 3), v3.version);
    try testing.expect(v2.gicc_base != 0); // GICv2 uses GICC
    try testing.expect(v3.gicr_base != 0); // GICv3 uses GICR
}

test "returns valid slice from HardwareInfo.memoryRegions" {
    var hw = HardwareInfo{};
    hw.memory_regions[0] = .{ .base = 0x8000_0000, .size = 0x1000_0000 };
    hw.memory_regions[1] = .{ .base = 0x4000_0000, .size = 0x800_0000 };
    hw.memory_region_count = 2;

    const regions = hw.memoryRegions();
    try testing.expectEqual(@as(usize, 2), regions.len);
    try testing.expectEqual(@as(u64, 0x8000_0000), regions[0].base);
    try testing.expectEqual(@as(u64, 0x4000_0000), regions[1].base);
}

test "returns valid slice from HardwareInfo.reservedRegions" {
    var hw = HardwareInfo{};
    hw.reserved_regions[0] = .{ .base = 0x8000_0000, .size = 0x20_0000 };
    hw.reserved_region_count = 1;

    const regions = hw.reservedRegions();
    try testing.expectEqual(@as(usize, 1), regions.len);
    try testing.expectEqual(@as(u64, 0x8000_0000), regions[0].base);
}

test "sorts regions by size descending" {
    var regions = [_]Region{
        .{ .base = 0x1000, .size = 100 },
        .{ .base = 0x2000, .size = 500 },
        .{ .base = 0x3000, .size = 200 },
    };

    sortRegionsBySize(&regions);

    try testing.expectEqual(@as(u64, 500), regions[0].size);
    try testing.expectEqual(@as(u64, 200), regions[1].size);
    try testing.expectEqual(@as(u64, 100), regions[2].size);
}

test "handles empty and single region in sortRegionsBySize" {
    var empty = [_]Region{};
    sortRegionsBySize(&empty);

    var single = [_]Region{.{ .base = 0x1000, .size = 100 }};
    sortRegionsBySize(&single);
    try testing.expectEqual(@as(u64, 100), single[0].size);
}
