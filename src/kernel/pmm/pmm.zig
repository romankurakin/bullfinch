//! Physical Memory Manager (PMM).
//!
//! Manages physical page allocation using a free list with optional bitmap verification.
//!
//! Both modes use free list for O(1) allocation:
//! - allocPage(): O(1) pop from free list
//! - freePage(): O(1) push to free list
//!
//! Debug build adds bitmap for verification (not allocation path):
//! - Double-free detection via bitmap
//! - Poison fills detect use-after-free and use-before-init
//! - verifyIntegrity() checks bitmap/free-list consistency
//! - allocatedRanges() iterator for leak detection
//!
//! Release build has no bitmap, minimal overhead.
//!
//! SMP: init() runs on primary core only. allocPage/freePage need external locking.
//!
//! TODO(smp): Add spinlock protecting regions array and free lists
//! TODO(smp): Consider per-CPU page caches to reduce lock contention

const builtin = @import("builtin");
const std = @import("std");
const fdt = @import("../fdt/fdt.zig");
const hal = @import("../hal/hal.zig");
const memory = @import("../memory/memory.zig");

const PAGE_SIZE = memory.PAGE_SIZE;

/// Enable bitmap tracking and poison fills in debug builds.
const debug_pmm = builtin.mode == .Debug;

/// Maximum number of memory regions supported.
const MAX_REGIONS = 4;

/// Maximum number of reserved ranges tracked.
const MAX_RESERVED = 8;

/// Poison patterns for detecting memory corruption.
const poison = struct {
    /// Filled on alloc - detects use-before-init.
    const ALLOC: u8 = 0xCD;
    /// Filled on free - detects use-after-free.
    const FREE: u8 = 0xDD;
};

const panic_msg = struct {
    const ALREADY_INITIALIZED = "PMM: already initialized";
    const NOT_INITIALIZED = "PMM: not initialized";
    const NO_MEMORY_REGIONS = "PMM: no memory regions found in DTB";
    const BITMAP_TOO_LARGE = "PMM: bitmap too large for available region";
    const FREE_LIST_BITMAP_MISMATCH = "PMM: free list length != bitmap free count";
    const UNALIGNED_ADDRESS = "PMM: freePage called with unaligned address";
    const ADDRESS_NOT_IN_REGION = "PMM: freePage address not in any managed region";
    const DOUBLE_FREE = "PMM: double-free detected";
    const OUT_OF_MEMORY = "PMM: out of memory";
};

/// Free list node embedded at start of each free page.
const FreeNode = struct {
    next: ?*FreeNode,
};

/// Memory range (for iteration).
pub const Range = struct { base: usize, pages: usize };

/// Iterator over allocated (used) memory ranges across all regions.
/// Only available in debug builds (requires bitmap).
pub const AllocatedRanges = struct {
    region_idx: usize = 0,
    pfn: usize = 0,

    pub fn next(self: *AllocatedRanges) ?Range {
        if (!debug_pmm) return null; // No bitmap in release mode

        while (self.region_idx < region_count) {
            const region = &regions[self.region_idx];

            // Find start of next allocated range in current region
            while (self.pfn < region.total_pages and !region.isAllocated(self.pfn)) : (self.pfn += 1) {}

            if (self.pfn >= region.total_pages) {
                // Move to next region
                self.region_idx += 1;
                self.pfn = 0;
                continue;
            }

            const start = self.pfn;
            // Find end of range
            while (self.pfn < region.total_pages and region.isAllocated(self.pfn)) : (self.pfn += 1) {}

            return .{ .base = region.base_addr + start * PAGE_SIZE, .pages = self.pfn - start };
        }
        return null;
    }
};

/// Single memory region with free list (and bitmap in debug builds).
const Region = struct {
    /// Bitmap for allocation tracking (debug only).
    bitmap: if (debug_pmm) []u8 else void = if (debug_pmm) &.{} else {},
    base_addr: usize = 0,
    total_pages: usize = 0,
    free_count: usize = 0,
    free_list: ?*FreeNode = null,

    fn containsAddr(self: Region, addr: usize) bool {
        if (self.total_pages == 0) return false;
        if (addr < self.base_addr) return false;
        const pfn = (addr - self.base_addr) / PAGE_SIZE;
        return pfn < self.total_pages;
    }

    fn physToPfn(self: Region, phys: usize) usize {
        return (phys - self.base_addr) / PAGE_SIZE;
    }

    fn pfnToPhys(self: Region, pfn: usize) usize {
        return self.base_addr + pfn * PAGE_SIZE;
    }

    fn isAllocated(self: Region, pfn: usize) bool {
        if (!debug_pmm) return false;
        const byte_idx = pfn / 8;
        const bit_idx: u3 = @intCast(pfn % 8);
        return (self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    fn markAllocated(self: *Region, pfn: usize) void {
        if (!debug_pmm) return;
        const byte_idx = pfn / 8;
        const bit_idx: u3 = @intCast(pfn % 8);
        self.bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
    }

    fn markFree(self: *Region, pfn: usize) void {
        if (!debug_pmm) return;
        const byte_idx = pfn / 8;
        const bit_idx: u3 = @intCast(pfn % 8);
        self.bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }

    // TODO(smp): Free list operations need lock protection.
    /// Pop a page from free list. Returns physical address or null.
    fn popFreeList(self: *Region) ?usize {
        const node = self.free_list orelse return null;
        const addr = @intFromPtr(node);
        const phys = hal.virtToPhys(addr);

        self.free_list = node.next;
        self.markAllocated(self.physToPfn(phys));
        self.free_count -= 1;

        return phys;
    }

    /// Push a page to free list.
    fn pushFreeList(self: *Region, phys: usize) void {
        const pfn = self.physToPfn(phys);
        self.markFree(pfn);
        self.free_count += 1;

        const virt = hal.physToVirt(phys);
        // SAFETY: page is free and mapped, safe to write FreeNode at start.
        const node: *FreeNode = @ptrFromInt(virt);
        node.next = self.free_list;
        self.free_list = node;
    }

    /// Build free list for all free pages.
    /// In debug mode: uses bitmap (bit=0 means free).
    /// In release mode: uses reserved range tracking.
    /// BOOT-TIME ONLY: runs on primary core before SMP.
    fn buildFreeList(self: *Region) void {
        var added: usize = 0;
        // Iterate forward for cache-friendly access, prepend to list
        for (0..self.total_pages) |pfn| {
            const phys = self.pfnToPhys(pfn);

            // Check if page is free
            const is_free = if (debug_pmm)
                !self.isAllocated(pfn) // Debug: bitmap bit=0 means free
            else
                !isReserved(phys); // Release: not in reserved ranges

            if (!is_free) continue;

            const virt = hal.physToVirt(phys);
            const node: *FreeNode = @ptrFromInt(virt);
            node.next = self.free_list;
            self.free_list = node;
            added += 1;
        }
        self.free_count = added;
    }
};

// TODO(smp): Protect with spinlock for concurrent access.
/// PMM state.
// SAFETY: align(64) prevents LLVM from merging these globals with others (cache line separation).
var regions: [MAX_REGIONS]Region align(64) = [_]Region{.{}} ** MAX_REGIONS;
var region_count: usize align(64) = 0;

/// Reserved ranges for release mode free list building.
var reserved_ranges: [MAX_RESERVED]struct { base: u64, end: u64 } align(64) = undefined;
var reserved_count: usize align(64) = 0;

/// Record a reserved range for release mode free list building.
fn recordReserved(base: u64, end: u64) void {
    if (!debug_pmm and reserved_count < MAX_RESERVED) {
        reserved_ranges[reserved_count] = .{ .base = base, .end = end };
        reserved_count += 1;
    }
}

/// Check if a physical address is in a reserved range.
fn isReserved(phys: u64) bool {
    for (reserved_ranges[0..reserved_count]) |r| {
        if (phys >= r.base and phys < r.end) return true;
    }
    return false;
}

/// Initialize PMM from DTB memory map.
/// BOOT-TIME ONLY: runs on primary core before SMP.
pub fn init(dtb: fdt.Fdt) void {
    // Reset state (allows re-initialization for testing)
    regions = [_]Region{.{}} ** MAX_REGIONS;
    region_count = 0;
    reserved_count = 0;

    // Collect memory regions from DTB, sorted by size (largest first for efficiency)
    var dtb_regions = fdt.getMemoryRegions(dtb);
    var candidates: [MAX_REGIONS]struct { base: u64, size: u64 } = undefined;
    var candidate_count: usize = 0;

    while (dtb_regions.next()) |region| {
        if (region.size == 0) continue;
        if (candidate_count >= MAX_REGIONS) break;

        // Insert sorted by size descending
        var insert_idx = candidate_count;
        while (insert_idx > 0 and candidates[insert_idx - 1].size < region.size) {
            candidates[insert_idx] = candidates[insert_idx - 1];
            insert_idx -= 1;
        }
        candidates[insert_idx] = .{ .base = region.base, .size = region.size };
        candidate_count += 1;
    }

    if (candidate_count == 0) {
        @panic(panic_msg.NO_MEMORY_REGIONS);
    }

    // Initialize each region
    for (candidates[0..candidate_count]) |candidate| {
        if (region_count >= MAX_REGIONS) break;
        if (initRegion(candidate.base, candidate.size)) {
            region_count += 1;
        }
    }

    if (region_count == 0) {
        @panic(panic_msg.NO_MEMORY_REGIONS);
    }

    // Mark kernel image as allocated
    const krange = hal.getKernelPhysRange();

    // Pad kernel memory reservation to at least 2MB.
    // This is a standard OS stability pattern:
    // 1. Safety Buffer: Covers BSS/Stack growth and bootloader artifacts (DTB) placed after the image.
    // 2. Alignment: Matches the architectural Large Page size (2MB on ARM64/RISC-V). Even if the
    //    linker image is smaller, we reserve the full large page to prevent PMM from fragmenting
    //    the kernel's identity mapping.
    const safe_end = @max(krange.end, krange.start + 2 * 1024 * 1024);

    recordReserved(krange.start, safe_end);
    markRangeUsed(krange.start, safe_end - krange.start);

    // Mark DTB reserved regions as allocated
    var reserved = fdt.getReservedRegions(dtb);
    while (reserved.next()) |region| {
        if (region.size > 0) {
            recordReserved(region.base, region.base + region.size);
            markRangeUsed(region.base, region.size);
        }
    }

    // Reserve DTB blob itself
    const dtb_size = fdt.getTotalSize(dtb);
    const dtb_start = hal.boot.dtb_ptr;
    if (dtb_start != 0 and dtb_size > 0) {
        recordReserved(dtb_start, dtb_start + dtb_size);
        markRangeUsed(dtb_start, dtb_size);
    }

    // Build free list now that reserved ranges are known (both modes)
    for (regions[0..region_count]) |*region| {
        region.buildFreeList();
    }
}

/// Initialize a single memory region. Returns true if successful.
fn initRegion(base: u64, size: u64) bool {
    const aligned_base = alignUp64(base, PAGE_SIZE);
    if (aligned_base >= base +% size) return false;

    const aligned_size = (base +% size) - aligned_base;
    const total_pages: usize = @intCast(aligned_size / PAGE_SIZE);
    if (total_pages == 0) return false;

    const base_usize: usize = @intCast(aligned_base);

    var region = &regions[region_count];
    region.base_addr = base_usize;
    region.total_pages = total_pages;
    region.free_list = null;

    if (debug_pmm) {
        // Debug mode: allocate bitmap, lazy free list
        const bitmap_bytes: usize = (total_pages + 7) / 8;
        const bitmap_pages = (bitmap_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

        if (bitmap_pages >= total_pages) {
            // Region too small for bitmap, skip it
            return false;
        }

        // Place bitmap at end of region. This keeps low addresses free
        // for kernel heap growth and avoids fragmenting the allocatable space.
        const bitmap_phys: usize = base_usize + (total_pages - bitmap_pages) * PAGE_SIZE;
        const bitmap_virt = hal.physToVirt(bitmap_phys);

        // SAFETY: bitmap_virt is within physmap (all RAM mapped at boot).
        const bitmap_ptr: [*]u8 = @ptrFromInt(bitmap_virt);
        region.bitmap = bitmap_ptr[0..bitmap_bytes];

        // Initialize bitmap: all pages free (bit=0)
        @memset(region.bitmap, 0x00);
        region.free_count = total_pages;

        // Mark bitmap pages as used
        const bitmap_start_pfn = (bitmap_phys - base_usize) / PAGE_SIZE;
        for (bitmap_start_pfn..bitmap_start_pfn + bitmap_pages) |pfn| {
            if (pfn < total_pages) {
                region.markAllocated(pfn);
                region.free_count -= 1;
            }
        }
    } else {
        // Release mode: no bitmap, free list built after reserved ranges marked
        region.free_count = total_pages;
        // Free list built in init() after reserved ranges are known
    }

    return true;
}

/// Mark a physical range as used across all regions. Removes from free list.
fn markRangeUsed(base: u64, size: u64) void {
    if (size == 0) return;

    const range_end: u64 = base +% size;

    for (regions[0..region_count]) |*region| {
        if (region.total_pages == 0) continue;

        const region_base: u64 = region.base_addr;
        const region_end: u64 = region_base +% (@as(u64, region.total_pages) * PAGE_SIZE);

        // Check if range overlaps with this region
        if (range_end <= region_base or base >= region_end) continue;

        // Clamp to this region
        const start: u64 = @max(base, region_base);
        const end: u64 = @min(range_end, region_end);
        if (end <= start) continue;

        // Calculate page range
        const start_pfn: usize = @intCast((start - region_base) / PAGE_SIZE);
        const end_offset = end - region_base;
        const end_pfn: usize = @intCast((end_offset + PAGE_SIZE - 1) / PAGE_SIZE);
        const clamped_end_pfn = @min(end_pfn, region.total_pages);

        if (debug_pmm) {
            // Debug: mark pages as used in bitmap (idempotent)
            for (start_pfn..clamped_end_pfn) |pfn| {
                if (!region.isAllocated(pfn)) {
                    region.markAllocated(pfn);
                    region.free_count -= 1;
                }
            }
        }

        // Remove from free list if already built (post-init runtime).
        // Count actual removals to update free_count correctly.
        if (region.free_list != null) {
            var new_list: ?*FreeNode = null;
            var kept: usize = 0;
            var node = region.free_list;
            while (node) |n| {
                const next_node = n.next;
                const node_phys = hal.virtToPhys(@intFromPtr(n));
                const node_pfn = region.physToPfn(node_phys);

                // Keep only pages not in the reserved range
                if (node_pfn < start_pfn or node_pfn >= clamped_end_pfn) {
                    n.next = new_list;
                    new_list = n;
                    kept += 1;
                }
                node = next_node;
            }
            // Update free_count based on actual removals (works for overlapping ranges)
            if (!debug_pmm) {
                region.free_count = kept;
            }
            region.free_list = new_list;
        }
        // Release mode during init: don't update free_count here.
        // buildFreeList() will set the correct value after all ranges are marked.
    }
}

fn alignUp64(value: u64, alignment: usize) u64 {
    const mask = @as(u64, alignment - 1);
    return (value + mask) & ~mask;
}

// TODO(smp): Caller must hold PMM lock for allocPage/freePage.
/// Allocate a single physical page. Returns physical address or null if OOM.
/// O(1) from free list. Bitmap (debug mode) is only for verification, not allocation.
pub fn allocPage() ?usize {
    if (region_count == 0) {
        @panic(panic_msg.NOT_INITIALIZED);
    }

    // Try each region in order (largest first due to sorting)
    for (regions[0..region_count]) |*region| {
        if (region.popFreeList()) |addr| {
            if (debug_pmm) poisonPage(addr, poison.ALLOC);
            return addr;
        }
    }

    return null;
}

/// Free a previously allocated page. Panics on double-free or invalid address.
pub fn freePage(addr: usize) void {
    if (region_count == 0) {
        @panic(panic_msg.NOT_INITIALIZED);
    }

    if (addr & (PAGE_SIZE - 1) != 0) {
        @panic(panic_msg.UNALIGNED_ADDRESS);
    }

    // Find which region owns this address
    for (regions[0..region_count]) |*region| {
        if (!region.containsAddr(addr)) continue;

        // Double-free detection (debug only - bitmap required)
        if (debug_pmm) {
            const pfn = region.physToPfn(addr);
            if (!region.isAllocated(pfn)) {
                @panic(panic_msg.DOUBLE_FREE);
            }
        }

        if (debug_pmm) poisonPage(addr, poison.FREE);
        region.pushFreeList(addr);
        return;
    }

    @panic(panic_msg.ADDRESS_NOT_IN_REGION);
}

/// Returns count of allocated pages across all regions.
pub fn allocatedCount() usize {
    if (region_count == 0) return 0;
    var total: usize = 0;
    for (regions[0..region_count]) |region| {
        total += region.total_pages - region.free_count;
    }
    return total;
}

/// Returns count of free pages across all regions.
pub fn freeCount() usize {
    if (region_count == 0) return 0;
    var total: usize = 0;
    for (regions[0..region_count]) |region| {
        total += region.free_count;
    }
    return total;
}

/// Returns total pages across all regions.
pub fn totalPages() usize {
    if (region_count == 0) return 0;
    var total: usize = 0;
    for (regions[0..region_count]) |region| {
        total += region.total_pages;
    }
    return total;
}

/// Returns number of managed regions.
pub fn regionCount() usize {
    return region_count;
}

/// Returns true if debug mode is enabled (bitmap tracking, poison fills).
pub fn isDebugEnabled() bool {
    return debug_pmm;
}

/// Returns base physical address of first (largest) region.
pub fn baseAddr() usize {
    if (region_count == 0) return 0;
    return regions[0].base_addr;
}

/// Returns iterator over allocated memory ranges (for leak detection).
/// Returns empty iterator in release builds.
pub fn allocatedRanges() AllocatedRanges {
    return .{};
}

/// Fill page with poison pattern (debug only).
fn poisonPage(phys: usize, pattern: u8) void {
    if (!debug_pmm) return;
    const virt = hal.physToVirt(phys);
    const ptr: [*]u8 = @ptrFromInt(virt);
    @memset(ptr[0..PAGE_SIZE], pattern);
}

/// Verify bitmap and free list consistency for all regions.
/// Bitmap is source of truth; free list is subset of free pages.
/// Always returns true in release builds (no bitmap to verify).
pub fn verifyIntegrity() bool {
    if (!debug_pmm) return true; // No bitmap in release mode
    if (region_count == 0) return true;

    for (regions[0..region_count]) |region| {
        // Count free bits in bitmap
        var bitmap_free: usize = 0;
        for (0..region.total_pages) |pfn| {
            if (!region.isAllocated(pfn)) {
                bitmap_free += 1;
            }
        }

        // Bitmap free count must match tracked free_count
        if (bitmap_free != region.free_count) {
            return false;
        }

        // Verify all free list entries are marked free in bitmap
        var node = region.free_list;
        while (node) |n| {
            const node_phys = hal.virtToPhys(@intFromPtr(n));
            const node_pfn = region.physToPfn(node_phys);
            if (region.isAllocated(node_pfn)) {
                // Page in free list but marked allocated in bitmap
                return false;
            }
            node = n.next;
        }
    }
    return true;
}

test "alignUp64 rounds to page boundaries" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(u64, 0), alignUp64(0, 4096));
    try expectEqual(@as(u64, 4096), alignUp64(1, 4096));
    try expectEqual(@as(u64, 4096), alignUp64(4095, 4096));
    try expectEqual(@as(u64, 4096), alignUp64(4096, 4096));
    try expectEqual(@as(u64, 8192), alignUp64(4097, 4096));
}

test "bitmap bit indexing is correct" {
    const expectEqual = std.testing.expectEqual;

    // Verify byte index
    try expectEqual(@as(usize, 0), @as(usize, 0) / 8);
    try expectEqual(@as(usize, 0), @as(usize, 7) / 8);
    try expectEqual(@as(usize, 1), @as(usize, 8) / 8);
    try expectEqual(@as(usize, 1), @as(usize, 15) / 8);

    // Verify bit index
    try expectEqual(@as(u3, 0), @as(u3, @intCast(@as(usize, 0) % 8)));
    try expectEqual(@as(u3, 7), @as(u3, @intCast(@as(usize, 7) % 8)));
    try expectEqual(@as(u3, 0), @as(u3, @intCast(@as(usize, 8) % 8)));
    try expectEqual(@as(u3, 1), @as(u3, @intCast(@as(usize, 9) % 8)));
}

test "bitmap masks set correct bits" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(@as(u8, 0b00000001), @as(u8, 1) << @as(u3, 0));
    try expectEqual(@as(u8, 0b00000010), @as(u8, 1) << @as(u3, 1));
    try expectEqual(@as(u8, 0b10000000), @as(u8, 1) << @as(u3, 7));
}

test "Region.containsAddr checks bounds correctly" {
    var region = Region{
        .base_addr = 0x1000,
        .total_pages = 4,
        .bitmap = &.{},
    };

    const expect = std.testing.expect;
    try expect(!region.containsAddr(0x0000));
    try expect(!region.containsAddr(0x0FFF));
    try expect(region.containsAddr(0x1000));
    try expect(region.containsAddr(0x2000));
    try expect(region.containsAddr(0x4FFF));
    try expect(!region.containsAddr(0x5000));
    try expect(!region.containsAddr(0x10000));
}

test "FreeNode size fits in page" {
    const expect = std.testing.expect;
    try expect(@sizeOf(FreeNode) <= PAGE_SIZE);
}
