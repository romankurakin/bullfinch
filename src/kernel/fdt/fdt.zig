//! Minimal libfdt bindings for DTB parsing.
//!
//! Provides memory discovery and device enumeration.

const std = @import("std");

/// Opaque handle for FDT blob.
pub const Fdt = *const anyopaque;

extern fn fdt_check_header(fdt: Fdt) c_int;
extern fn fdt_totalsize(fdt: Fdt) u32;
extern fn fdt_path_offset(fdt: Fdt, path: [*:0]const u8) c_int;
extern fn fdt_getprop(fdt: Fdt, nodeoffset: c_int, name: [*:0]const u8, lenp: *c_int) ?*const anyopaque;
extern fn fdt_first_subnode(fdt: Fdt, offset: c_int) c_int;
extern fn fdt_next_subnode(fdt: Fdt, offset: c_int) c_int;
extern fn fdt_get_name(fdt: Fdt, nodeoffset: c_int, lenp: ?*c_int) ?[*:0]const u8;

/// Check if the FDT header is valid.
pub fn checkHeader(fdt: Fdt) error{InvalidHeader}!void {
    if (fdt_check_header(fdt) != 0) return error.InvalidHeader;
}

/// Get total size of DTB blob in bytes.
pub fn totalSize(fdt: Fdt) u32 {
    return fdt_totalsize(fdt);
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

/// Parse memory region from /memory node.
pub fn getMemoryRegion(fdt: Fdt) ?Region {
    const offset = fdt_path_offset(fdt, "/memory");
    if (offset < 0) return null;
    return parseReg(fdt, offset);
}

/// Parse first reg entry (base + size) from any node.
pub fn parseReg(fdt: Fdt, offset: i32) ?Region {
    const reg = getprop(fdt, offset, "reg") orelse return null;
    if (reg.len < 16) return null;
    return .{
        .base = std.mem.readInt(u64, reg[0..8], .big),
        .size = std.mem.readInt(u64, reg[8..16], .big),
    };
}
