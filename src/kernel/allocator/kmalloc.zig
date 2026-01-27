//! Kmalloc-style front-end for kernel buffers.
//!
//! Keeps allocation simple and predictable for variable-size kernel data. Sizes
//! round up to the smallest power-of-two class up to 1KB, with cache-line
//! alignment by default to avoid false sharing. Optional alignment must be a
//! power of two and no larger than a cache line. Requests above 1KB return
//! error.TooLarge and must use other allocators.
//!
//! Backed by slab pools and PMM pages.
//!
//! TODO(debug): add redzones, canaries, and a small quarantine to delay reuse.
//!
//! ```
//! allocator.init();
//! const buf = allocator.alloc(256, null) catch return error.OutOfMemory;
//! defer allocator.free(buf) catch @panic("kmalloc: free failed");
//! ```

const std = @import("std");
const hal = @import("../hal/hal.zig");
const pmm = @import("../pmm/pmm.zig");
const slab = @import("slab.zig");

const panic_msg = struct {
    const ALREADY_INITIALIZED = "kmalloc: already initialized";
    const NOT_INITIALIZED = "kmalloc: not initialized";
    const DOUBLE_FREE = "kmalloc: double-free";
    const CORRUPTED_FREE = "kmalloc: corrupted free";
};

pub const AllocError = error{
    OutOfMemory,
    BadAlignment,
    TooLarge,
};

const CACHE_LINE_SIZE = 64;
/// Maximum size handled by slab classes.
const MAX_CLASS = 1024;

const SizeClass = enum(u8) {
    c64,
    c128,
    c256,
    c512,
    c1024,
};

fn Obj(comptime size: usize) type {
    return extern struct { data: [size]u8 };
}

const Pool64 = slab.Pool(Obj(64));
const Pool128 = slab.Pool(Obj(128));
const Pool256 = slab.Pool(Obj(256));
const Pool512 = slab.Pool(Obj(512));
const Pool1024 = slab.Pool(Obj(1024));

var pool_64: Pool64 = undefined;
var pool_128: Pool128 = undefined;
var pool_256: Pool256 = undefined;
var pool_512: Pool512 = undefined;
var pool_1024: Pool1024 = undefined;

var initialized = false;

/// Initialize allocator front-end. Must be called after PMM init.
pub fn init() void {
    if (initialized) @panic(panic_msg.ALREADY_INITIALIZED);
    pool_64 = Pool64.init(pmmAllocPage, pmmFreePage, seedFor(&pool_64, 64));
    pool_128 = Pool128.init(pmmAllocPage, pmmFreePage, seedFor(&pool_128, 128));
    pool_256 = Pool256.init(pmmAllocPage, pmmFreePage, seedFor(&pool_256, 256));
    pool_512 = Pool512.init(pmmAllocPage, pmmFreePage, seedFor(&pool_512, 512));
    pool_1024 = Pool1024.init(pmmAllocPage, pmmFreePage, seedFor(&pool_1024, 1024));
    initialized = true;
}

/// Allocate a kernel buffer. Size classes are power-of-two up to MAX_CLASS.
/// Returns error.BadAlignment if alignment is not power-of-two or exceeds cache line.
pub fn alloc(size: usize, alignment: ?usize) AllocError!*u8 {
    if (!initialized) @panic(panic_msg.NOT_INITIALIZED);

    if (alignment) |a| {
        if (a == 0 or !std.math.isPowerOfTwo(a) or a > CACHE_LINE_SIZE) {
            return error.BadAlignment;
        }
    }

    if (size > MAX_CLASS) return error.TooLarge;

    const want = @max(size, CACHE_LINE_SIZE);
    const class = sizeToClass(want) orelse return error.TooLarge;

    return switch (class) {
        .c64 => @ptrCast(pool_64.alloc() orelse return error.OutOfMemory),
        .c128 => @ptrCast(pool_128.alloc() orelse return error.OutOfMemory),
        .c256 => @ptrCast(pool_256.alloc() orelse return error.OutOfMemory),
        .c512 => @ptrCast(pool_512.alloc() orelse return error.OutOfMemory),
        .c1024 => @ptrCast(pool_1024.alloc() orelse return error.OutOfMemory),
    };
}

/// Free a kernel buffer previously allocated by alloc().
pub fn free(ptr: *u8) slab.FreeError!void {
    if (!initialized) @panic(panic_msg.NOT_INITIALIZED);

    if (tryFree(&pool_64, ptr)) return;
    if (tryFree(&pool_128, ptr)) return;
    if (tryFree(&pool_256, ptr)) return;
    if (tryFree(&pool_512, ptr)) return;
    if (tryFree(&pool_1024, ptr)) return;

    return error.InvalidSlab;
}

fn tryFree(pool_inst: anytype, ptr: *u8) bool {
    const PoolType = @TypeOf(pool_inst.*);
    const obj: *Obj(PoolType.aligned_size) = @ptrCast(@alignCast(ptr));
    pool_inst.free(obj) catch |err| switch (err) {
        error.InvalidSlab => return false,
        error.DoubleFree => @panic(panic_msg.DOUBLE_FREE),
        error.MisalignedPointer, error.MetadataSlot, error.OutOfBounds => {
            @panic(panic_msg.CORRUPTED_FREE);
        },
    };
    return true;
}

fn sizeToClass(size: usize) ?SizeClass {
    if (size <= 64) return .c64;
    if (size <= 128) return .c128;
    if (size <= 256) return .c256;
    if (size <= 512) return .c512;
    if (size <= 1024) return .c1024;
    return null;
}

fn seedFor(pool_ptr: anytype, size: usize) usize {
    // Collect hardware entropy mixed with pool address for per-pool uniqueness.
    // Uses RNDR on ARM64, seed CSR on RISC-V, with timer fallback.
    const addr_hint = @intFromPtr(pool_ptr) ^ size;
    return hal.entropy.collectMixed(addr_hint);
}

fn pmmAllocPage() ?usize {
    const page = pmm.allocPage() orelse return null;
    const phys = pmm.pageToPhys(page);
    return hal.mmu.physToVirt(phys);
}

fn pmmFreePage(addr: usize) void {
    const phys = hal.mmu.virtToPhys(addr);
    const page = pmm.physToPage(phys) orelse @panic("kmalloc: freePage unknown phys");
    pmm.freePage(page);
}
