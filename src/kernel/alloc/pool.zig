//! Fixed-Size Object Pool Allocator.
//!
//! Multi-page pool for kernel objects. Alloc is O(bitmap_words) in the worst
//! case, but bitmap_words is typically 1-2 for common kernel objects (≤960B),
//! making it effectively O(1). Free is always O(1). Objects are cache-line
//! aligned (64B) to prevent false sharing on SMP.
//!
//! See Bonwick, "The Slab Allocator" (USENIX Summer 1994).
//!
//! Slab layout (4KB page):
//! +---------+---------------------+------+------+-----+------+
//! | backptr | SlabData (+ bitmap) | obj1 | obj2 | ... | objN |
//! +---------+---------------------+------+------+-----+------+
//! ^         ^
//! 0         64 (slot 0)
//!
//! Each slab is self-contained: back-pointer at page start points to SlabData
//! in slot 0, which contains the free bitmap. This avoids needing a separate
//! allocator for metadata (chicken-and-egg problem).
//!
//! Allocation scans the bitmap with @ctz (count trailing zeros) to find the
//! first free slot. Complexity is O(bitmap_words), but for typical kernel
//! objects this is 1-2 words. Pool tracks a "current" slab hint for fast path.
//! When current slab fills, we check partial slabs or allocate a new page.
//!
//! Free masks the object pointer to page boundary, reads the back-pointer to
//! find SlabData, calculates slot index via subtraction, and sets the bitmap
//! bit. All O(1) operations.
//!
//! Debug builds include checks for double-free, misaligned free, and freeing
//! unallocated pointers.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../sync/sync.zig");
const memory = @import("../memory/memory.zig");

const PAGE_SIZE = memory.PAGE_SIZE;

/// Errors returned by pool free operations.
pub const FreeError = error{
    /// Pointer not aligned to object boundary.
    MisalignedPointer,
    /// Attempted to free slab metadata slot.
    MetadataSlot,
    /// Pointer outside valid slot range.
    OutOfBounds,
    /// Slot already free (double-free).
    DoubleFree,
};

/// Enable extra validation in debug builds.
const debug_kernel = builtin.mode == .Debug;

const panic_msg = struct {
    const SLAB_NO_FREE_SLOTS = "pool: slab has no free slots";
};

/// 64 bytes - standard cache line on ARM64 and modern x86.
/// Ensures two objects never share a cache line (prevents false sharing).
const CACHE_LINE_SIZE = 64;

/// Back-pointer size at start of each slab page.
const BACKPTR_SIZE = @sizeOf(usize);

/// Minimum slabs to keep allocated to prevent thrashing at alloc/free boundary.
const MIN_SLABS = 1;

/// Page allocator function type. Returns directly-mapped address or null.
pub const PageAllocFn = *const fn () ?usize;

/// Page deallocator function type.
pub const PageFreeFn = *const fn (usize) void;

/// Generic fixed-size object pool with automatic growth.
///
/// ```
/// // Create pool with PMM backing:
/// var pool = Pool(Thread).init(pmmAllocPage, pmmFreePage);
///
/// // Allocate object (returns null if OOM):
/// const thread = pool.alloc() orelse return error.OutOfMemory;
/// defer pool.free(thread);
/// ```
pub fn Pool(comptime T: type) type {
    // Cache-line alignment prevents false sharing when different cores access adjacent objects
    const raw_object_size = @max(@sizeOf(T), 1);
    const object_size = std.mem.alignForward(usize, raw_object_size, CACHE_LINE_SIZE);

    // Calculate capacity per slab, accounting for back-pointer at start and bitmap at end
    const usable_start = std.mem.alignForward(usize, BACKPTR_SIZE, CACHE_LINE_SIZE);

    const objects_per_slab = comptime blk: {
        var max_objects = (PAGE_SIZE - usable_start) / object_size;
        var words_needed = (max_objects + 63) / 64;
        while (usable_start + max_objects * object_size + words_needed * 8 > PAGE_SIZE) {
            max_objects -= 1;
            if (max_objects == 0) break;
            words_needed = (max_objects + 63) / 64;
        }
        break :blk max_objects;
    };

    const bitmap_words = (objects_per_slab + 63) / 64;

    comptime {
        if (objects_per_slab == 0) @compileError("Object too large for single page");
    }

    return struct {
        const Self = @This();

        /// Page allocator function.
        alloc_page: PageAllocFn,
        /// Page deallocator function.
        free_page: PageFreeFn,

        /// Current slab for allocation (has free space).
        current: ?*SlabData = null,
        /// List of slabs with free space.
        partial_head: ?*SlabData = null,
        /// Total allocated objects across all slabs.
        total_allocated: usize = 0,
        /// Total slabs allocated.
        slab_count: usize = 0,

        /// Lock for SMP safety.
        /// TODO(smp): Add per-CPU magazine cache for lock-free fast path.
        /// See Bonwick, "Magazines and Vmem" (USENIX 2001).
        lock: sync.SpinLock = .{},

        /// Internal slab tracking data. Lives in slot 0 of each slab page.
        const SlabData = struct {
            /// Page base address (must be directly mapped).
            page_addr: usize,
            /// Free slot bitmap. Bit semantics: 1 = free, 0 = allocated.
            bitmap: [bitmap_words]u64,
            free_count: usize,
            next: ?*SlabData,
            prev: ?*SlabData,
            in_partial_list: bool,
        };

        comptime {
            // SlabData must fit in slot 0 (one object_size worth of space)
            if (@sizeOf(SlabData) > object_size) {
                @compileError("SlabData too large for slot 0");
            }
        }

        /// Max objects per slab (compile-time constant).
        pub const capacity_per_slab = objects_per_slab;

        /// Object size after cache-line alignment.
        pub const aligned_size = object_size;

        /// Initialize pool with page allocator functions.
        pub fn init(alloc_page: PageAllocFn, free_page: PageFreeFn) Self {
            return Self{
                .alloc_page = alloc_page,
                .free_page = free_page,
            };
        }

        /// Allocate object. Returns null if out of memory.
        pub fn alloc(self: *Self) ?*T {
            const held = self.lock.guard();
            defer held.release();

            // Try current slab first
            if (self.current) |slab| {
                if (slab.free_count > 0) {
                    if (self.allocFromSlab(slab)) |obj| {
                        return obj;
                    }
                }
                // Current slab is full, try to get another
                self.current = self.partial_head;
            }

            // Try partial list
            while (self.current) |slab| {
                if (slab.free_count > 0) {
                    if (self.allocFromSlab(slab)) |obj| {
                        return obj;
                    }
                }
                self.current = slab.next;
            }

            // Need new slab
            const new_slab = self.allocNewSlab() orelse return null;
            self.current = new_slab;
            return self.allocFromSlab(new_slab);
        }

        fn allocFromSlab(self: *Self, slab: *SlabData) ?*T {
            // Caller already checked free_count > 0.
            // Debug-only since we trust internal callers per error philosophy.
            if (debug_kernel and slab.free_count == 0) @panic(panic_msg.SLAB_NO_FREE_SLOTS);

            // Find first free slot via @ctz (bit=1 means free)
            for (&slab.bitmap, 0..) |*word, word_idx| {
                if (word.* == 0) continue;

                const bit_idx = @ctz(word.*);
                const slot_idx = word_idx * 64 + bit_idx;
                if (slot_idx >= objects_per_slab) break;

                // Mark allocated
                word.* &= ~(@as(u64, 1) << @intCast(bit_idx));
                slab.free_count -= 1;
                self.total_allocated += 1;

                // Slab became full - remove from partial list
                if (slab.free_count == 0) {
                    self.unlinkSlab(slab);
                }

                // Get object pointer
                const storage_base = slab.page_addr + usable_start;
                const obj_addr = storage_base + slot_idx * object_size;
                const obj: *T = @ptrFromInt(obj_addr);

                if (debug_kernel) {
                    const bytes: *[object_size]u8 = @ptrCast(obj);
                    @memset(bytes, 0);
                }

                return obj;
            }
            return null;
        }

        fn linkSlab(self: *Self, slab: *SlabData) void {
            slab.next = self.partial_head;
            slab.prev = null;
            if (self.partial_head) |head| {
                head.prev = slab;
            }
            self.partial_head = slab;
            slab.in_partial_list = true;
        }

        fn unlinkSlab(self: *Self, slab: *SlabData) void {
            if (!slab.in_partial_list) return;

            if (slab.prev) |prev| {
                prev.next = slab.next;
            } else {
                self.partial_head = slab.next;
            }
            if (slab.next) |next| {
                next.prev = slab.prev;
            }
            slab.prev = null;
            slab.next = null;
            slab.in_partial_list = false;

            // If current pointed to this slab, advance it
            if (self.current == slab) {
                self.current = self.partial_head;
            }
        }

        fn allocNewSlab(self: *Self) ?*SlabData {
            const page_addr = self.alloc_page() orelse return null;

            // SlabData lives in slot 0, avoiding external allocator dependency
            const slab_storage = page_addr + usable_start;
            const slab: *SlabData = @ptrFromInt(slab_storage);

            // Initialize bitmap: all 1s = all free, then mask unused bits
            var bitmap: [bitmap_words]u64 = undefined;
            for (&bitmap) |*word| {
                word.* = std.math.maxInt(u64);
            }
            const used_bits = objects_per_slab % 64;
            if (used_bits != 0 and bitmap_words > 0) {
                bitmap[bitmap_words - 1] = (@as(u64, 1) << @intCast(used_bits)) - 1;
            }
            // Mark slot 0 as used (holds SlabData)
            bitmap[0] &= ~@as(u64, 1);

            slab.* = .{
                .page_addr = page_addr,
                .bitmap = bitmap,
                .free_count = objects_per_slab - 1, // -1 because slot 0 used for SlabData
                .next = null,
                .prev = null,
                .in_partial_list = false,
            };

            // Write back-pointer at page start for O(1) free lookup
            const backptr: **SlabData = @ptrFromInt(page_addr);
            backptr.* = slab;

            self.linkSlab(slab);
            self.slab_count += 1;

            return slab;
        }

        /// Return object to pool.
        pub fn free(self: *Self, obj: *T) FreeError!void {
            const held = self.lock.guard();
            defer held.release();

            const obj_addr = @intFromPtr(obj);
            const page_base = obj_addr & ~@as(usize, PAGE_SIZE - 1);

            // Read back-pointer to find slab
            const backptr: **SlabData = @ptrFromInt(page_base);
            const slab = backptr.*;

            // Calculate slot index
            const storage_base = page_base + usable_start;
            const offset = obj_addr - storage_base;

            if (offset % object_size != 0) {
                return error.MisalignedPointer;
            }

            const slot_idx = offset / object_size;
            if (slot_idx == 0) {
                return error.MetadataSlot;
            }
            if (slot_idx >= objects_per_slab) {
                return error.OutOfBounds;
            }

            const word_idx = slot_idx / 64;
            const bit_idx: u6 = @intCast(slot_idx % 64);
            const bit_mask = @as(u64, 1) << bit_idx;

            if (slab.bitmap[word_idx] & bit_mask != 0) {
                return error.DoubleFree;
            }

            if (debug_kernel) {
                const bytes: *[object_size]u8 = @ptrCast(obj);
                @memset(bytes, 0xDD);
            }

            const was_full = slab.free_count == 0;
            slab.bitmap[word_idx] |= bit_mask;
            slab.free_count += 1;
            self.total_allocated -= 1;

            // Slab completely empty - return page to PMM unless at minimum.
            // Keeping MIN_SLABS avoids thrashing when near alloc/free boundary.
            const max_free = objects_per_slab - 1; // slot 0 holds SlabData
            const is_empty = slab.free_count == max_free;
            if (is_empty and self.slab_count > MIN_SLABS) {
                self.unlinkSlab(slab);
                self.slab_count -= 1;
                // Poison backptr to catch use-after-free
                if (debug_kernel) {
                    const poison_ptr: *usize = @ptrFromInt(slab.page_addr);
                    poison_ptr.* = 0xDEAD_BEEF_DEAD_BEEF;
                }
                self.free_page(slab.page_addr);
                return;
            }

            // Slab was full (not in partial list), now has space - add back and
            // make it current so next alloc finds it immediately
            if (was_full) {
                self.linkSlab(slab);
                self.current = slab;
            }
        }

        /// Returns total allocated objects. Read without lock; may be stale.
        pub fn totalAllocated(self: *const Self) usize {
            return self.total_allocated;
        }

        /// Returns number of allocated slabs. Read without lock; may be stale.
        pub fn slabCount(self: *const Self) usize {
            return self.slab_count;
        }
    };
}

const testing = std.testing;

// Mock page allocator for testing
var test_pages: [8][PAGE_SIZE]u8 align(PAGE_SIZE) = undefined;
var test_page_idx: usize = 0;
var test_freed_pages: [8]usize = undefined;
var test_freed_count: usize = 0;

fn testAllocPage() ?usize {
    if (test_page_idx >= test_pages.len) return null;
    const page = &test_pages[test_page_idx];
    test_page_idx += 1;
    return @intFromPtr(page);
}

fn testFreePage(addr: usize) void {
    test_freed_pages[test_freed_count] = addr;
    test_freed_count += 1;
}

fn resetTestPages() void {
    test_page_idx = 0;
    test_freed_count = 0;
}

test "Pool capacity calculation" {
    const SmallObj = extern struct { data: [32]u8 };
    const SmallPool = Pool(SmallObj);

    try testing.expect(SmallPool.capacity_per_slab > 0);
    try testing.expectEqual(@as(usize, CACHE_LINE_SIZE), SmallPool.aligned_size);
}

test "Pool alloc and free" {
    resetTestPages();

    const TestObj = extern struct { id: u32, data: [60]u8 };
    const TestPool = Pool(TestObj);

    var pool = TestPool.init(testAllocPage, testFreePage);

    const obj1 = pool.alloc() orelse return error.AllocFailed;
    const obj2 = pool.alloc() orelse return error.AllocFailed;
    obj1.id = 1;
    obj2.id = 2;

    try testing.expectEqual(@as(usize, 2), pool.totalAllocated());

    try pool.free(obj1);
    try testing.expectEqual(@as(usize, 1), pool.totalAllocated());

    try pool.free(obj2);
    try testing.expectEqual(@as(usize, 0), pool.totalAllocated());
}

test "Pool grows with multiple slabs" {
    resetTestPages();

    const TestObj = extern struct { data: [960]u8 }; // Large object, few per slab
    const TestPool = Pool(TestObj);

    var pool = TestPool.init(testAllocPage, testFreePage);

    // Allocate more than one slab can hold
    var objs: [10]*TestObj = undefined;
    var count: usize = 0;

    for (&objs) |*slot| {
        slot.* = pool.alloc() orelse break;
        count += 1;
    }

    try testing.expect(count > 0);
    try testing.expect(pool.slabCount() >= 1);

    // Free all
    for (objs[0..count]) |obj| {
        try pool.free(obj);
    }

    try testing.expectEqual(@as(usize, 0), pool.totalAllocated());
}

test "Pool free finds correct slab via back-pointer" {
    resetTestPages();

    const TestObj = extern struct { value: u64, padding: [56]u8 };
    const TestPool = Pool(TestObj);

    var pool = TestPool.init(testAllocPage, testFreePage);

    // Allocate objects that span multiple slabs
    const obj1 = pool.alloc() orelse return error.AllocFailed;
    const obj2 = pool.alloc() orelse return error.AllocFailed;

    obj1.value = 0xDEADBEEF;
    obj2.value = 0xCAFEBABE;

    // Free in reverse order - tests that back-pointer lookup works
    try pool.free(obj2);
    try pool.free(obj1);

    try testing.expectEqual(@as(usize, 0), pool.totalAllocated());
}

test "Pool reuses freed slot from full slab" {
    resetTestPages();

    const TestObj = extern struct { value: u64, padding: [56]u8 };
    const TestPool = Pool(TestObj);

    var pool = TestPool.init(testAllocPage, testFreePage);

    // Allocate until slab is full
    var objs: [TestPool.capacity_per_slab]*TestObj = undefined;
    for (objs[0 .. TestPool.capacity_per_slab - 1], 1..) |*slot, i| {
        slot.* = pool.alloc() orelse return error.AllocFailed;
        slot.*.value = i;
    }

    try testing.expectEqual(@as(usize, 1), pool.slabCount());

    // Free one object
    const freed_addr = @intFromPtr(objs[0]);
    try pool.free(objs[0]);

    // Next alloc should reuse the freed slot (slab became current on free)
    const reused = pool.alloc() orelse return error.AllocFailed;
    try testing.expectEqual(freed_addr, @intFromPtr(reused));
    try testing.expectEqual(@as(usize, 1), pool.slabCount());
}

test "Pool reclaims empty slab when above MIN_SLABS" {
    resetTestPages();

    const TestObj = extern struct { value: u64, padding: [56]u8 };
    const TestPool = Pool(TestObj);

    var pool = TestPool.init(testAllocPage, testFreePage);

    // Fill first slab completely to force second slab allocation
    const cap = TestPool.capacity_per_slab - 1; // -1 for SlabData in slot 0
    var slab1_objs: [63]*TestObj = undefined; // max possible capacity
    for (slab1_objs[0..cap]) |*slot| {
        slot.* = pool.alloc() orelse return error.AllocFailed;
    }

    // Allocate one more to create second slab
    const slab2_obj = pool.alloc() orelse return error.AllocFailed;
    try testing.expectEqual(@as(usize, 2), pool.slabCount());

    const second_slab_page = @intFromPtr(&test_pages[1]);

    // Free the object in second slab - slab should be reclaimed (above MIN_SLABS)
    try pool.free(slab2_obj);

    try testing.expectEqual(@as(usize, 1), pool.slabCount());
    try testing.expectEqual(@as(usize, 1), test_freed_count);
    try testing.expectEqual(second_slab_page, test_freed_pages[0]);

    // Clean up first slab
    for (slab1_objs[0..cap]) |obj| {
        try pool.free(obj);
    }
}
