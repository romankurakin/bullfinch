//! Physical Memory Manager (PMM).
//!
//! Manages physical page allocation using per-page metadata and a doubly-linked
//! free list. Supports single page and contiguous allocation with SMP-safe locking.
//!
//! Each Page struct (24 bytes) tracks one 4KB physical page. Pages are grouped
//! into Arenas discovered from the DTB. Metadata lives at end of each arena to
//! keep low addresses free for DMA. Overhead is ~0.6% of RAM.
//!
//! - allocPage / freePage: O(1)
//! - allocContiguous: O(n) scan for N consecutive free pages
//! - pageToPhys / physToPage: O(1) pointer arithmetic
//!
//! Debug builds enable poison fills (0xCD alloc, 0xDD free) and double-free detection.
//!
//! ```
//! // Single page:
//! const page = pmm.allocPage() orelse return error.OutOfMemory;
//! defer pmm.freePage(page);
//! const phys = pmm.pageToPhys(page);
//!
//! // Contiguous (e.g., 16KB stack):
//! const pages = pmm.allocContiguous(4, 0) orelse return error.OutOfMemory;
//! defer pmm.freeContiguous(pages, 4);
//! ```

const builtin = @import("builtin");
const std = @import("std");
const fdt = @import("../fdt/fdt.zig");
const hal = @import("../hal/hal.zig");
const memory = @import("../memory/memory.zig");
const sync = @import("../sync/sync.zig");

const lib = @import("../lib/lib.zig");
pub const ListNode = lib.ListNode;
pub const DoublyLinkedList = lib.DoublyLinkedList;

const PAGE_SIZE = memory.PAGE_SIZE;

/// Enable poison fills and extra validation in debug builds.
const debug_kernel = builtin.mode == .Debug;

/// Maximum number of memory arenas supported.
const MAX_ARENAS = 4;

/// Maximum number of reserved ranges tracked during init.
const MAX_RESERVED = 8;

comptime {
    // Page metadata capped at 24 bytes (~0.6% overhead per 4KB page).
    // Currently 19 bytes + padding = 24 bytes due to 8-byte alignment.
    if (@sizeOf(Page) > 24) @compileError("Page struct too large (max 24 bytes)");
    // Page must fit evenly for pointer arithmetic in pageToPhys
    if (@sizeOf(Page) % @alignOf(Page) != 0) @compileError("Page size must be multiple of alignment");
    // Poison patterns must be distinct
    if (poison.ALLOC == poison.FREE) @compileError("Poison patterns must differ");
    // MAX constants must be reasonable
    if (MAX_ARENAS == 0) @compileError("MAX_ARENAS must be > 0");
    if (MAX_RESERVED == 0) @compileError("MAX_RESERVED must be > 0");
}

/// Poison patterns for detecting memory corruption.
const poison = struct {
    /// Filled on alloc - detects use-before-init.
    const ALLOC: u8 = 0xCD;
    /// Filled on free - detects use-after-free.
    const FREE: u8 = 0xDD;
};

const panic_msg = struct {
    const NOT_INITIALIZED = "PMM: not initialized";
    const NO_MEMORY_REGIONS = "PMM: no memory regions found in DTB";
    const METADATA_TOO_LARGE = "PMM: page metadata too large for region";
    const UNALIGNED_ADDRESS = "PMM: address not page-aligned";
    const ADDRESS_NOT_IN_ARENA = "PMM: address not in any managed arena";
    const DOUBLE_FREE = "PMM: double-free detected";
    const FREE_RESERVED = "PMM: attempted to free reserved page";
    const INVALID_PAGE_STATE = "PMM: invalid page state";
    const NOT_CONTIGUOUS_HEAD = "PMM: freeContiguous called on non-head page";
    const TOO_MANY_RESERVED = "PMM: too many reserved regions (increase MAX_RESERVED)";
    const INVALID_ALIGNMENT = "PMM: alignment_log2 exceeds address space width";
    const CONTIGUOUS_NOT_ALLOCATED = "PMM: freeContiguous page not in allocated state";
    const ARENA_IDX_MISMATCH = "PMM: arena_idx mismatch - page not in indicated arena";
};

/// Physical page states.
pub const PageState = enum(u8) {
    /// Page is on free list, available for allocation.
    free,
    /// Page is allocated and in use.
    allocated,
    /// Page is reserved (kernel, DTB, metadata) and cannot be freed.
    reserved,
};

/// Per-page metadata. One instance per physical page in the system.
/// Size is enforced at compile time to keep overhead low (~0.6% of RAM).
pub const Page = struct {
    /// Intrusive list node for free list membership.
    node: ListNode = .{},

    /// Current page state.
    state: PageState = .free,

    /// Index of arena that owns this page.
    arena_idx: u8 = 0,

    /// Flags for special pages.
    flags: Flags = .{},

    pub const Flags = packed struct {
        /// True if this is the first page of a contiguous allocation.
        contiguous_head: bool = false,
        /// Reserved for future use.
        _reserved: u7 = 0,
    };
};

/// Physical memory arena - a contiguous region of RAM.
///
/// Each arena discovered from the device tree gets its own metadata array
/// placed at the end of the region.
pub const Arena = struct {
    /// Physical base address of this arena.
    base_phys: usize = 0,

    /// Total number of pages in this arena.
    page_count: usize = 0,

    /// Number of usable pages (excludes metadata pages).
    usable_pages: usize = 0,

    /// Page metadata array (one Page per physical page).
    /// Allocated from the arena itself during init.
    pages: []Page = &.{},

    /// Convert physical address to Page pointer.
    /// Returns null if address is not page-aligned or not in this arena.
    pub fn physToPage(self: *const Arena, phys: usize) ?*Page {
        if (phys & (PAGE_SIZE - 1) != 0) return null;
        if (phys < self.base_phys) return null;
        const offset = phys - self.base_phys;
        const pfn = offset / PAGE_SIZE;
        if (pfn >= self.page_count) return null;
        return &self.pages[pfn];
    }

    /// Convert Page pointer to physical address.
    pub fn pageToPhys(self: *const Arena, page: *const Page) usize {
        const idx = (@intFromPtr(page) - @intFromPtr(self.pages.ptr)) / @sizeOf(Page);
        return self.base_phys + idx * PAGE_SIZE;
    }

    /// Check if physical address is within this arena.
    pub fn containsPhys(self: *const Arena, phys: usize) bool {
        if (phys < self.base_phys) return false;
        const offset = phys - self.base_phys;
        return offset < self.page_count * PAGE_SIZE;
    }
};

/// Free list type using doubly-linked intrusive list.
const FreeList = DoublyLinkedList(Page, "node");

/// PMM global state.
const Pmm = struct {
    /// Memory arenas discovered from device tree.
    arenas: [MAX_ARENAS]Arena = [_]Arena{.{}} ** MAX_ARENAS,
    arena_count: usize = 0,

    /// Global free list of available pages.
    free_list: FreeList = .{},

    /// Lock protecting all PMM state.
    lock: sync.SpinLock = .{},

    /// Statistics.
    total_pages: usize = 0,
    free_count: usize = 0,
};

/// Global PMM instance. Cache-line aligned to prevent false sharing.
var pmm: Pmm align(64) = .{};

/// Reserved range for tracking during initialization.
const ReservedRange = struct { base: u64 = 0, end: u64 = 0 };

/// Reserved ranges tracked during initialization (before free list is built).
var reserved_ranges: [MAX_RESERVED]ReservedRange = .{ReservedRange{}} ** MAX_RESERVED;
var reserved_count: usize = 0;

/// Initialize PMM from device tree memory map.
/// Must be called on primary core before SMP initialization.
pub fn init(dtb: fdt.Fdt) void {
    // Reset state (allows re-initialization for testing)
    pmm = Pmm{};
    reserved_count = 0;

    // Reserve DTB and kernel FIRST, before placing metadata.
    // DTB is typically placed near end of RAM by bootloader.
    // If we don't reserve it first, our metadata array may overwrite it.

    // Reserve kernel image (padded to 2MB for large page alignment)
    const krange = hal.getKernelPhysRange();
    const kernel_safe_end = @max(krange.end, krange.start + 2 * 1024 * 1024);
    recordReserved(krange.start, kernel_safe_end);

    // Reserve DTB blob (must be done before iterating reserved regions!)
    const dtb_size = fdt.getTotalSize(dtb);
    const dtb_start = hal.boot.dtb_ptr;
    if (dtb_start != 0 and dtb_size > 0) {
        // Pad DTB reservation to page boundary
        const dtb_end = alignUp64(dtb_start + dtb_size, PAGE_SIZE);
        recordReserved(dtb_start, dtb_end);
    }

    // Reserve DTB-specified reserved regions (e.g., OpenSBI on RISC-V)
    var dtb_reserved = fdt.getReservedRegions(dtb);
    while (dtb_reserved.next()) |region| {
        if (region.size > 0) {
            recordReserved(region.base, region.base + region.size);
        }
    }

    // Collect memory regions from DTB, sorted by size (largest first)
    var dtb_regions = fdt.getMemoryRegions(dtb);
    var candidates: [MAX_ARENAS]struct { base: u64, size: u64 } = undefined;
    var candidate_count: usize = 0;

    while (dtb_regions.next()) |region| {
        if (region.size == 0) continue;
        if (candidate_count >= MAX_ARENAS) break;

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

    // Initialize each arena
    for (candidates[0..candidate_count], 0..) |candidate, idx| {
        if (pmm.arena_count >= MAX_ARENAS) break;
        if (initArena(candidate.base, candidate.size, @intCast(idx))) {
            pmm.arena_count += 1;
        }
    }

    if (pmm.arena_count == 0) {
        @panic(panic_msg.NO_MEMORY_REGIONS);
    }

    // Mark all pre-recorded reserved ranges in the page metadata
    // (ranges were recorded before arena init to protect DTB from being overwritten)
    for (reserved_ranges[0..reserved_count]) |r| {
        if (r.end > r.base) {
            markRangeReserved(r.base, r.end - r.base);
        }
    }

    // Build free list from non-reserved pages
    buildFreeList();
}

/// Allocate a single physical page.
/// Returns Page pointer or null if out of memory.
/// O(1) operation.
pub fn allocPage() ?*Page {
    if (pmm.arena_count == 0) {
        @panic(panic_msg.NOT_INITIALIZED);
    }

    const held = pmm.lock.guard();
    defer held.release();

    const page = pmm.free_list.popFront() orelse return null;

    page.state = .allocated;
    pmm.free_count -= 1;

    if (debug_kernel) {
        const phys = pageToPhysInternal(page);
        poisonPage(phys, poison.ALLOC);
    }

    return page;
}

/// Free a previously allocated page.
/// Panics on double-free, freeing reserved pages, or invalid address.
pub fn freePage(page: *Page) void {
    if (pmm.arena_count == 0) {
        @panic(panic_msg.NOT_INITIALIZED);
    }

    const held = pmm.lock.guard();
    defer held.release();

    freePageLocked(page);
}

/// Allocate N contiguous physical pages with specified alignment.
/// Returns head Page pointer or null if unable to satisfy request.
/// O(n) scan across all arenas; prefer allocPage() for single pages.
///
/// alignment_log2: log2 of physical address alignment for the first page.
///                 Values <= 12 are effectively page-aligned (4KB minimum).
///                 Use 21 for 2MB large-page alignment, 30 for 1GB.
///                 Must be < @bitSizeOf(usize).
pub fn allocContiguous(count: usize, alignment_log2: u8) ?*Page {
    if (pmm.arena_count == 0) {
        @panic(panic_msg.NOT_INITIALIZED);
    }

    if (count == 0) return null;

    // Validate alignment to prevent undefined shift behavior
    if (alignment_log2 >= @bitSizeOf(usize)) {
        @panic(panic_msg.INVALID_ALIGNMENT);
    }

    const held = pmm.lock.guard();
    defer held.release();

    const alignment: usize = @as(usize, 1) << @intCast(alignment_log2);

    // Search each arena for a contiguous run
    for (pmm.arenas[0..pmm.arena_count]) |*arena| {
        if (arena.usable_pages < count) continue;

        var run_start: ?usize = null;
        var run_length: usize = 0;

        for (0..arena.usable_pages) |i| {
            const page = &arena.pages[i];

            // Reset run if page is not free
            if (page.state != .free) {
                run_start = null;
                run_length = 0;
                continue;
            }

            // Check alignment for potential run start
            if (run_start == null) {
                const phys = arena.base_phys + i * PAGE_SIZE;
                if (phys & (alignment - 1) == 0) {
                    run_start = i;
                    run_length = 1;
                } else {
                    continue;
                }
            } else {
                run_length += 1;
            }

            // Found enough contiguous pages?
            if (run_length >= count) {
                const start_idx = run_start.?;

                // Remove all pages from free list and mark allocated
                for (start_idx..start_idx + count) |j| {
                    const p = &arena.pages[j];

                    // Verify page is actually free before removal
                    if (debug_kernel) {
                        std.debug.assert(p.state == .free);
                    }

                    pmm.free_list.remove(p);
                    p.state = .allocated;

                    if (debug_kernel) {
                        const phys = arena.base_phys + j * PAGE_SIZE;
                        poisonPage(phys, poison.ALLOC);
                    }
                }

                // Mark head page
                arena.pages[start_idx].flags.contiguous_head = true;
                pmm.free_count -= count;

                return &arena.pages[start_idx];
            }
        }
    }

    return null;
}

/// Free a contiguous allocation.
/// The page must be the head of a contiguous allocation.
/// Caller must pass the exact count used during allocation.
pub fn freeContiguous(head: *Page, count: usize) void {
    if (pmm.arena_count == 0) {
        @panic(panic_msg.NOT_INITIALIZED);
    }

    if (count == 0) return;

    if (!head.flags.contiguous_head) {
        @panic(panic_msg.NOT_CONTIGUOUS_HEAD);
    }

    const held = pmm.lock.guard();
    defer held.release();

    // Find arena containing this page
    const arena = findArenaForPage(head) orelse @panic(panic_msg.ADDRESS_NOT_IN_ARENA);
    const start_idx = (@intFromPtr(head) - @intFromPtr(arena.pages.ptr)) / @sizeOf(Page);

    // Validate all pages in range are allocated (not free/reserved) before freeing any.
    // This catches caller errors like wrong count or double-free of contiguous range.
    for (start_idx..start_idx + count) |i| {
        if (i >= arena.usable_pages) {
            @panic(panic_msg.ADDRESS_NOT_IN_ARENA);
        }
        const page = &arena.pages[i];
        if (page.state != .allocated) {
            @panic(panic_msg.CONTIGUOUS_NOT_ALLOCATED);
        }
        // Ensure no nested contiguous_head (except the first page)
        if (i != start_idx and page.flags.contiguous_head) {
            @panic(panic_msg.INVALID_PAGE_STATE);
        }
    }

    // Clear contiguous_head flag before freeing (freePageLocked will clear all flags,
    // but we clear it explicitly first for clarity)
    head.flags.contiguous_head = false;

    // Now free all pages
    for (start_idx..start_idx + count) |i| {
        freePageLocked(&arena.pages[i]);
    }
}

/// Get physical address from Page pointer.
pub fn pageToPhys(page: *const Page) usize {
    return pageToPhysInternal(page);
}

/// Get Page pointer from physical address.
/// Returns null if address is not managed by PMM.
pub fn physToPage(phys: usize) ?*Page {
    if (phys & (PAGE_SIZE - 1) != 0) return null;

    for (pmm.arenas[0..pmm.arena_count]) |*arena| {
        if (arena.physToPage(phys)) |page| {
            return page;
        }
    }
    return null;
}

/// Returns count of free pages.
pub fn freeCount() usize {
    return @atomicLoad(usize, &pmm.free_count, .acquire);
}

/// Returns total pages across all arenas. Constant after init.
pub fn totalPages() usize {
    return pmm.total_pages;
}

/// Returns count of allocated pages.
pub fn allocatedCount() usize {
    return pmm.total_pages - @atomicLoad(usize, &pmm.free_count, .acquire);
}

/// Returns number of managed arenas.
pub fn arenaCount() usize {
    return pmm.arena_count;
}

/// Returns base physical address of first (largest) arena.
pub fn baseAddr() usize {
    if (pmm.arena_count == 0) return 0;
    return pmm.arenas[0].base_phys;
}

/// Initialize a single arena. Returns true if successful.
fn initArena(base: u64, size: u64, arena_idx: u8) bool {
    const aligned_base = alignUp64(base, PAGE_SIZE);
    if (aligned_base >= base +% size) return false;

    const aligned_size = (base +% size) - aligned_base;
    const total_pages: usize = @intCast(aligned_size / PAGE_SIZE);
    if (total_pages == 0) return false;

    // Calculate metadata size
    const metadata_bytes = total_pages * @sizeOf(Page);
    const metadata_pages = (metadata_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    if (metadata_pages >= total_pages) {
        // Region too small for metadata
        return false;
    }

    const usable_pages = total_pages - metadata_pages;
    const base_usize: usize = @intCast(aligned_base);

    // Place metadata at end of region
    const metadata_phys = base_usize + usable_pages * PAGE_SIZE;
    const metadata_virt = hal.physToVirt(metadata_phys);

    // Initialize arena
    var arena = &pmm.arenas[pmm.arena_count];
    arena.base_phys = base_usize;
    arena.page_count = total_pages;
    arena.usable_pages = usable_pages;

    // metadata_virt is within physmap (all RAM mapped at boot)
    const pages_ptr: [*]Page = @ptrFromInt(metadata_virt);
    arena.pages = pages_ptr[0..total_pages];

    // Initialize all Page structs
    for (arena.pages, 0..) |*page, i| {
        page.* = Page{
            .arena_idx = arena_idx,
            .state = if (i >= usable_pages) .reserved else .free,
        };
    }

    // Mark metadata pages as reserved
    recordReserved(metadata_phys, metadata_phys + metadata_pages * PAGE_SIZE);

    pmm.total_pages += usable_pages;

    return true;
}

/// Record a reserved range for reference.
fn recordReserved(base: u64, end: u64) void {
    if (reserved_count >= MAX_RESERVED) {
        @panic(panic_msg.TOO_MANY_RESERVED);
    }
    reserved_ranges[reserved_count] = .{ .base = base, .end = end };
    reserved_count += 1;
}

/// Check if physical address is in a reserved range.
fn isReserved(phys: u64) bool {
    for (reserved_ranges[0..reserved_count]) |r| {
        if (phys >= r.base and phys < r.end) return true;
    }
    return false;
}

/// Mark a physical range as reserved.
fn markRangeReserved(base: u64, size: u64) void {
    if (size == 0) return;

    const range_end: u64 = base +% size;

    for (pmm.arenas[0..pmm.arena_count]) |*arena| {
        if (arena.page_count == 0) continue;

        const arena_base: u64 = arena.base_phys;
        const arena_end: u64 = arena_base + arena.usable_pages * PAGE_SIZE;

        // Check overlap
        if (range_end <= arena_base or base >= arena_end) continue;

        // Clamp to arena
        const start: u64 = @max(base, arena_base);
        const end: u64 = @min(range_end, arena_end);
        if (end <= start) continue;

        // Calculate page range
        const start_pfn: usize = @intCast((start - arena_base) / PAGE_SIZE);
        const end_pfn: usize = @intCast((end - arena_base + PAGE_SIZE - 1) / PAGE_SIZE);
        const clamped_end = @min(end_pfn, arena.usable_pages);

        // Mark pages as reserved
        for (start_pfn..clamped_end) |pfn| {
            arena.pages[pfn].state = .reserved;
        }
    }
}

/// Build free list from all non-reserved pages.
fn buildFreeList() void {
    pmm.free_list = .{};
    pmm.free_count = 0;

    for (pmm.arenas[0..pmm.arena_count]) |*arena| {
        for (0..arena.usable_pages) |i| {
            const page = &arena.pages[i];

            // Skip if reserved or already marked
            if (page.state == .reserved) continue;

            // Double-check against reserved ranges
            const phys = arena.base_phys + i * PAGE_SIZE;
            if (isReserved(phys)) {
                page.state = .reserved;
                continue;
            }

            // Add to free list
            page.state = .free;
            pmm.free_list.pushBack(page);
            pmm.free_count += 1;
        }
    }
}

/// Free a page (must hold lock).
fn freePageLocked(page: *Page) void {
    switch (page.state) {
        .free => @panic(panic_msg.DOUBLE_FREE),
        .reserved => @panic(panic_msg.FREE_RESERVED),
        .allocated => {},
    }

    if (debug_kernel) {
        const phys = pageToPhysInternal(page);
        poisonPage(phys, poison.FREE);
    }

    page.state = .free;
    page.flags = .{};
    pmm.free_list.pushBack(page);
    pmm.free_count += 1;
}

/// Get physical address from Page (internal, no lock needed).
fn pageToPhysInternal(page: *const Page) usize {
    const arena = findArenaForPage(page) orelse @panic(panic_msg.ADDRESS_NOT_IN_ARENA);
    return arena.pageToPhys(page);
}

/// Find arena containing a Page pointer.
/// Uses the stored arena_idx for O(1) lookup instead of scanning.
fn findArenaForPage(page: *const Page) ?*Arena {
    const idx = page.arena_idx;
    if (idx >= pmm.arena_count) return null;

    const arena = &pmm.arenas[idx];

    // Verify page pointer is actually in this arena's metadata
    if (debug_kernel) {
        const page_addr = @intFromPtr(page);
        const start = @intFromPtr(arena.pages.ptr);
        const end = start + arena.pages.len * @sizeOf(Page);
        if (page_addr < start or page_addr >= end) {
            @panic(panic_msg.ARENA_IDX_MISMATCH);
        }
    }

    return arena;
}

/// Fill page with poison pattern (debug only).
fn poisonPage(phys: usize, pattern: u8) void {
    if (!debug_kernel) return;
    const virt = hal.physToVirt(phys);
    const ptr: [*]u8 = @ptrFromInt(virt);
    @memset(ptr[0..PAGE_SIZE], pattern);
}

fn alignUp64(value: u64, alignment: usize) u64 {
    const mask = @as(u64, alignment - 1);
    return (value + mask) & ~mask;
}

test "Page size is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Page));
}

test "alignUp64 rounds to page boundaries" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(u64, 0), alignUp64(0, 4096));
    try expectEqual(@as(u64, 4096), alignUp64(1, 4096));
    try expectEqual(@as(u64, 4096), alignUp64(4095, 4096));
    try expectEqual(@as(u64, 4096), alignUp64(4096, 4096));
    try expectEqual(@as(u64, 8192), alignUp64(4097, 4096));
}

test "Arena.physToPage and pageToPhys roundtrip" {
    var pages: [4]Page = [_]Page{.{}} ** 4;
    var arena = Arena{
        .base_phys = 0x1000,
        .page_count = 4,
        .usable_pages = 4,
        .pages = &pages,
    };

    // Test each page
    for (0..4) |i| {
        const phys = 0x1000 + i * PAGE_SIZE;
        const page = arena.physToPage(phys).?;
        try std.testing.expectEqual(phys, arena.pageToPhys(page));
    }

    // Out of range
    try std.testing.expectEqual(@as(?*Page, null), arena.physToPage(0x0000));
    try std.testing.expectEqual(@as(?*Page, null), arena.physToPage(0x5000));
}

test "Arena.containsPhys" {
    var pages: [4]Page = [_]Page{.{}} ** 4;
    var arena = Arena{
        .base_phys = 0x1000,
        .page_count = 4,
        .usable_pages = 4,
        .pages = &pages,
    };

    try std.testing.expect(!arena.containsPhys(0x0000));
    try std.testing.expect(!arena.containsPhys(0x0FFF));
    try std.testing.expect(arena.containsPhys(0x1000));
    try std.testing.expect(arena.containsPhys(0x4FFF));
    try std.testing.expect(!arena.containsPhys(0x5000));
}

test "Page default state is free" {
    const page = Page{};
    try std.testing.expectEqual(PageState.free, page.state);
    try std.testing.expect(!page.flags.contiguous_head);
}

test "Page.Flags is packed and minimal" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Page.Flags));
}

test {
    _ = lib; // Include lib tests
}
