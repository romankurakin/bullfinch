//! Minimal libfdt bindings for DTB parsing.
//!
//! Provides memory discovery and device enumeration.

const std = @import("std");

/// Opaque handle for FDT blob.
pub const Fdt = *const anyopaque;

extern fn fdt_check_header(fdt: Fdt) c_int;
extern fn fdt_path_offset(fdt: Fdt, path: [*:0]const u8) c_int;
extern fn fdt_getprop(fdt: Fdt, nodeoffset: c_int, name: [*:0]const u8, lenp: *c_int) ?*const anyopaque;
extern fn fdt_first_subnode(fdt: Fdt, offset: c_int) c_int;
extern fn fdt_next_subnode(fdt: Fdt, offset: c_int) c_int;
extern fn fdt_get_name(fdt: Fdt, nodeoffset: c_int, lenp: ?*c_int) ?[*:0]const u8;
extern fn fdt_node_offset_by_compatible(fdt: Fdt, startoffset: c_int, compatible: [*:0]const u8) c_int;

/// Check if the FDT header is valid.
pub fn checkHeader(fdt: Fdt) error{InvalidHeader}!void {
    if (fdt_check_header(fdt) != 0) return error.InvalidHeader;
}

/// Get total size of DTB blob in bytes.
pub fn getTotalSize(fdt: Fdt) u32 {
    const ptr: [*]const u8 = @ptrCast(fdt);
    // totalsize is at offset 4 in big-endian
    return std.mem.readInt(u32, ptr[4..8], .big);
}

/// Find a node by path (e.g., "/memory", "/soc").
pub fn pathOffset(fdt: Fdt, path: [:0]const u8) ?i32 {
    const result = fdt_path_offset(fdt, path.ptr);
    return if (result < 0) null else result;
}

/// Get raw property bytes.
pub fn getprop(fdt: Fdt, offset: i32, name: [:0]const u8) ?[]const u8 {
    var len: c_int = 0;
    const ptr = fdt_getprop(fdt, offset, name.ptr, &len) orelse return null;
    return if (len <= 0) null else @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
}

/// Get compatible string (first entry only).
pub fn getCompatible(fdt: Fdt, offset: i32) ?[]const u8 {
    const prop = getprop(fdt, offset, "compatible") orelse return null;
    return std.mem.sliceTo(prop, 0);
}

/// Get node name (e.g., "uart@10000000").
pub fn getName(fdt: Fdt, offset: i32) ?[]const u8 {
    const ptr = fdt_get_name(fdt, offset, null) orelse return null;
    return std.mem.span(ptr);
}

/// Get first child node.
pub fn firstSubnode(fdt: Fdt, offset: i32) ?i32 {
    const result = fdt_first_subnode(fdt, offset);
    return if (result < 0) null else result;
}

/// Get next sibling node.
pub fn nextSubnode(fdt: Fdt, offset: i32) ?i32 {
    const result = fdt_next_subnode(fdt, offset);
    return if (result < 0) null else result;
}

/// Memory/MMIO region (base + size).
pub const Region = struct {
    base: u64,
    size: u64,
};

/// Cell sizes for parsing reg properties. Each cell is 4 bytes.
pub const CellSizes = struct {
    addr_cells: u8, // Typically 1 (32-bit) or 2 (64-bit)
    size_cells: u8,

    fn entrySize(self: CellSizes) usize {
        return (@as(usize, self.addr_cells) + self.size_cells) * 4;
    }
};

/// Read #address-cells and #size-cells from a node. Defaults to 2,1 per DTB spec.
pub fn getCellSizes(fdt: Fdt, parent_offset: i32) CellSizes {
    return .{
        .addr_cells = readU32Prop(fdt, parent_offset, "#address-cells") orelse 2,
        .size_cells = readU32Prop(fdt, parent_offset, "#size-cells") orelse 1,
    };
}

fn readU32Prop(fdt: Fdt, offset: i32, name: [:0]const u8) ?u8 {
    const prop = getprop(fdt, offset, name) orelse return null;
    if (prop.len < 4) return null;
    return @truncate(std.mem.readInt(u32, prop[0..4], .big));
}

/// Read value from reg property respecting cell count.
fn readCells(data: []const u8, cells: u8) u64 {
    return switch (cells) {
        1 => std.mem.readInt(u32, data[0..4], .big),
        2 => std.mem.readInt(u64, data[0..8], .big),
        else => 0,
    };
}

/// Parse reg entry at given byte offset using cell sizes.
fn parseRegEntry(data: []const u8, offset: usize, cells: CellSizes) ?Region {
    const entry_size = cells.entrySize();
    if (offset + entry_size > data.len) return null;
    const entry = data[offset..];
    const addr_bytes = @as(usize, cells.addr_cells) * 4;
    return .{
        .base = readCells(entry[0..], cells.addr_cells),
        .size = readCells(entry[addr_bytes..], cells.size_cells),
    };
}

/// Iterator over regions from DTB nodes with reg properties.
pub const RegionIterator = struct {
    fdt: Fdt,
    cells: CellSizes,
    node: ?i32,
    byte_offset: usize,
    prefix: ?[]const u8, // filter by node name prefix (e.g. "memory@")

    pub fn next(self: *RegionIterator) ?Region {
        while (self.node) |offset| {
            const reg = getprop(self.fdt, offset, "reg") orelse {
                self.byte_offset = 0;
                self.node = self.findNext(offset);
                continue;
            };
            if (parseRegEntry(reg, self.byte_offset, self.cells)) |region| {
                self.byte_offset += self.cells.entrySize();
                return region;
            }
            self.byte_offset = 0;
            self.node = self.findNext(offset);
        }
        return null;
    }

    fn findNext(self: RegionIterator, after: i32) ?i32 {
        var node = nextSubnode(self.fdt, after);
        while (node) |offset| {
            if (self.prefix) |p| {
                const name = getName(self.fdt, offset) orelse "";
                if (!std.mem.startsWith(u8, name, p)) {
                    node = nextSubnode(self.fdt, offset);
                    continue;
                }
            }
            return offset;
        }
        return null;
    }
};

fn findNodeByPrefix(fdt: Fdt, parent: i32, prefix: []const u8) ?i32 {
    var node = firstSubnode(fdt, parent);
    while (node) |offset| {
        const name = getName(fdt, offset) orelse "";
        if (std.mem.startsWith(u8, name, prefix)) return offset;
        node = nextSubnode(fdt, offset);
    }
    return null;
}

/// Get iterator over all memory regions.
pub fn getMemoryRegions(fdt: Fdt) RegionIterator {
    const root = pathOffset(fdt, "/") orelse 0;
    const cells = getCellSizes(fdt, root);
    const memory_offset = pathOffset(fdt, "/memory");
    return .{
        .fdt = fdt,
        .cells = cells,
        .node = memory_offset orelse findNodeByPrefix(fdt, root, "memory@"),
        .byte_offset = 0,
        .prefix = "memory@",
    };
}

/// Get total memory size across all regions.
pub fn getTotalMemory(fdt: Fdt) u64 {
    var total: u64 = 0;
    var regions = getMemoryRegions(fdt);
    while (regions.next()) |region| {
        total += region.size;
    }
    return total;
}

/// Get timer frequency from /cpus/timebase-frequency.
pub fn getTimerFrequency(fdt: Fdt) ?u64 {
    const offset = pathOffset(fdt, "/cpus") orelse return null;
    const prop = getprop(fdt, offset, "timebase-frequency") orelse return null;
    // Property can be u32 or u64 depending on DTB
    if (prop.len >= 8) {
        return std.mem.readInt(u64, prop[0..8], .big);
    } else if (prop.len >= 4) {
        return std.mem.readInt(u32, prop[0..4], .big);
    }
    return null;
}

/// Count CPU nodes under /cpus.
pub fn getCpuCount(fdt: Fdt) u32 {
    const cpus_offset = pathOffset(fdt, "/cpus") orelse return 0;
    var count: u32 = 0;
    var node = firstSubnode(fdt, cpus_offset);
    while (node) |offset| {
        const name = getName(fdt, offset) orelse "";
        if (std.mem.startsWith(u8, name, "cpu@")) count += 1;
        node = nextSubnode(fdt, offset);
    }
    return count;
}

/// Find first node matching compatible string. Searches entire tree.
pub fn findByCompatible(fdt_handle: Fdt, compatible: [:0]const u8) ?i32 {
    const result = fdt_node_offset_by_compatible(fdt_handle, -1, compatible.ptr);
    return if (result < 0) null else result;
}

/// GIC interrupt controller info discovered from DTB.
pub const GicInfo = struct {
    version: u8, // 2 or 3
    gicd_base: u64, // Distributor (both versions)
    gicc_base: u64, // CPU interface (GICv2 only)
    gicr_base: u64, // Redistributor (GICv3 only)
};

/// Find GIC info from DTB using libfdt tree search.
pub fn getGicInfo(fdt_handle: Fdt) ?GicInfo {
    const root = pathOffset(fdt_handle, "/") orelse return null;
    const cells = getCellSizes(fdt_handle, root);

    // GICv3
    if (findByCompatible(fdt_handle, "arm,gic-v3")) |offset| {
        return parseGicRegs(fdt_handle, offset, cells, 3);
    }

    // GICv2: QEMU uses cortex-a15-gic, RPi5 uses gic-400
    if (findByCompatible(fdt_handle, "arm,cortex-a15-gic")) |offset| {
        return parseGicRegs(fdt_handle, offset, cells, 2);
    }
    if (findByCompatible(fdt_handle, "arm,gic-400")) |offset| {
        return parseGicRegs(fdt_handle, offset, cells, 2);
    }

    return null;
}

fn parseGicRegs(fdt_handle: Fdt, offset: i32, cells: CellSizes, version: u8) ?GicInfo {
    const reg = getprop(fdt_handle, offset, "reg") orelse return null;
    const first = parseRegEntry(reg, 0, cells) orelse return null;
    const second = parseRegEntry(reg, cells.entrySize(), cells);

    return .{
        .version = version,
        .gicd_base = first.base,
        .gicc_base = if (version == 2) if (second) |r| r.base else 0 else 0,
        .gicr_base = if (version == 3) if (second) |r| r.base else 0 else 0,
    };
}

/// Get UART base address from DTB.
/// Kernel uses this for ARM64 console. Userland drivers use for any UART.
pub fn getUartBase(fdt_handle: Fdt) ?u64 {
    const root = pathOffset(fdt_handle, "/") orelse return null;
    const cells = getCellSizes(fdt_handle, root);

    // ARM PL011 (QEMU ARM64, RPi5)
    if (findByCompatible(fdt_handle, "arm,pl011")) |offset| {
        const reg = getprop(fdt_handle, offset, "reg") orelse return null;
        const region = parseRegEntry(reg, 0, cells) orelse return null;
        return region.base;
    }

    // 16550 (RISC-V) - kernel uses SBI, but userland driver needs this
    if (findByCompatible(fdt_handle, "ns16550a")) |offset| {
        const reg = getprop(fdt_handle, offset, "reg") orelse return null;
        const region = parseRegEntry(reg, 0, cells) orelse return null;
        return region.base;
    }

    return null;
}

/// Get iterator over reserved memory regions.
/// Physical allocator should exclude these from available memory.
pub fn getReservedRegions(fdt: Fdt) RegionIterator {
    const parent = pathOffset(fdt, "/reserved-memory");
    const cells = if (parent) |p| getCellSizes(fdt, p) else CellSizes{ .addr_cells = 2, .size_cells = 2 };
    return .{
        .fdt = fdt,
        .cells = cells,
        .node = if (parent) |p| firstSubnode(fdt, p) else null,
        .byte_offset = 0,
        .prefix = null, // iterate all children
    };
}

test "CellSizes.entrySize calculates correctly" {
    const cases = [_]struct { addr: u8, size: u8, expected: usize }{
        .{ .addr = 1, .size = 1, .expected = 8 }, // 32-bit addr + 32-bit size
        .{ .addr = 2, .size = 2, .expected = 16 }, // 64-bit addr + 64-bit size
        .{ .addr = 2, .size = 1, .expected = 12 }, // 64-bit addr + 32-bit size (DTB default)
    };

    for (cases) |case| {
        const cells = CellSizes{ .addr_cells = case.addr, .size_cells = case.size };
        try std.testing.expectEqual(case.expected, cells.entrySize());
    }
}

test "readCells parses big-endian values" {
    // 32-bit value
    const data32 = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try std.testing.expectEqual(@as(u64, 0x12345678), readCells(&data32, 1));

    // 64-bit value
    const data64 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u64, 0x80000000), readCells(&data64, 2));

    // Full 64-bit value
    const data64_full = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    try std.testing.expectEqual(@as(u64, 0x123456789ABCDEF0), readCells(&data64_full, 2));
}

test "parseRegEntry parses memory regions" {
    const cases = [_]struct {
        addr_cells: u8,
        size_cells: u8,
        data: []const u8,
        expected_base: u64,
        expected_size: u64,
    }{
        // 64-bit cells: RISC-V memory at 0x80000000, 128MB
        .{
            .addr_cells = 2,
            .size_cells = 2,
            .data = &[_]u8{
                0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
            },
            .expected_base = 0x80000000,
            .expected_size = 0x8000000,
        },
        // 32-bit cells: UART at 0x10000000, 4KB
        .{
            .addr_cells = 1,
            .size_cells = 1,
            .data = &[_]u8{ 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00 },
            .expected_base = 0x10000000,
            .expected_size = 0x1000,
        },
    };

    for (cases) |case| {
        const cells = CellSizes{ .addr_cells = case.addr_cells, .size_cells = case.size_cells };
        const region = parseRegEntry(case.data, 0, cells).?;
        try std.testing.expectEqual(case.expected_base, region.base);
        try std.testing.expectEqual(case.expected_size, region.size);
    }
}

test "parseRegEntry handles multiple entries" {
    const cells = CellSizes{ .addr_cells = 2, .size_cells = 1 };

    // GIC reg: GICD at 0x8000000 + GICR at 0x80A0000
    const reg = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x08, 0x0A, 0x00, 0x00, 0x00, 0xF6, 0x00, 0x00,
    };

    const region1 = parseRegEntry(&reg, 0, cells).?;
    try std.testing.expectEqual(@as(u64, 0x8000000), region1.base);
    try std.testing.expectEqual(@as(u64, 0x10000), region1.size);

    const region2 = parseRegEntry(&reg, cells.entrySize(), cells).?;
    try std.testing.expectEqual(@as(u64, 0x80A0000), region2.base);
    try std.testing.expectEqual(@as(u64, 0xF60000), region2.size);
}

test "parseRegEntry returns null for insufficient data" {
    const cells = CellSizes{ .addr_cells = 2, .size_cells = 2 };

    const short = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(parseRegEntry(&short, 0, cells) == null);
    try std.testing.expect(parseRegEntry(&short, 16, cells) == null);
}
