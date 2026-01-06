//! PMM Integration Tests.
//!
//! Standalone tests that exercise the PMM allocator logic without
//! requiring HAL or board dependencies. Uses a self-contained test
//! harness with its own memory region.

const std = @import("std");
const builtin = @import("builtin");

const PAGE_SIZE: usize = 4096;
const debug_mode = builtin.mode == .Debug;

/// Free list node (same as pmm.zig).
const FreeNode = struct {
    next: ?*FreeNode,
};

/// Test region with its own allocator state.
const TestAllocator = struct {
    const NUM_PAGES = 16;
    const MEM_SIZE = NUM_PAGES * PAGE_SIZE;
    const BITMAP_SIZE = (NUM_PAGES + 7) / 8;

    memory: [MEM_SIZE]u8 align(PAGE_SIZE) = undefined,
    bitmap: [BITMAP_SIZE]u8 = [_]u8{0} ** BITMAP_SIZE,
    free_list: ?*FreeNode = null,
    free_count: usize = 0,
    total_pages: usize = NUM_PAGES,
    base_addr: usize = 0,

    fn init(self: *TestAllocator) void {
        self.base_addr = @intFromPtr(&self.memory);
        self.free_list = null;
        self.free_count = NUM_PAGES;

        // Initialize bitmap: all free (bit=0)
        @memset(&self.bitmap, 0x00);

        // Build free list
        for (0..NUM_PAGES) |i| {
            const page_addr = self.base_addr + i * PAGE_SIZE;
            const node: *FreeNode = @ptrFromInt(page_addr);
            node.next = self.free_list;
            self.free_list = node;
        }
    }

    fn allocPage(self: *TestAllocator) ?usize {
        const node = self.free_list orelse return null;
        const addr = @intFromPtr(node);

        self.free_list = node.next;
        self.free_count -= 1;

        // Mark allocated in bitmap
        if (debug_mode) {
            const pfn = (addr - self.base_addr) / PAGE_SIZE;
            const byte_idx = pfn / 8;
            const bit_idx: u3 = @intCast(pfn % 8);
            self.bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
        }

        return addr;
    }

    fn freePage(self: *TestAllocator, addr: usize) void {
        // Verify alignment
        if (addr & (PAGE_SIZE - 1) != 0) {
            @panic("freePage: unaligned address");
        }

        // Verify in range
        if (addr < self.base_addr or addr >= self.base_addr + MEM_SIZE) {
            @panic("freePage: address not in region");
        }

        // Double-free check (debug only)
        if (debug_mode) {
            const pfn = (addr - self.base_addr) / PAGE_SIZE;
            const byte_idx = pfn / 8;
            const bit_idx: u3 = @intCast(pfn % 8);
            if ((self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
                @panic("freePage: double-free detected");
            }
            // Mark free
            self.bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
        }

        // Push to free list
        const node: *FreeNode = @ptrFromInt(addr);
        node.next = self.free_list;
        self.free_list = node;
        self.free_count += 1;
    }

    fn allocatedCount(self: *const TestAllocator) usize {
        return self.total_pages - self.free_count;
    }

    fn verifyIntegrity(self: *const TestAllocator) bool {
        if (!debug_mode) return true;

        // Count free list nodes
        var list_count: usize = 0;
        var node = self.free_list;
        while (node) |n| : (node = n.next) {
            list_count += 1;
            if (list_count > self.total_pages) return false; // Cycle detected
        }

        // Should match free_count
        if (list_count != self.free_count) return false;

        // Count bitmap free bits
        var bitmap_free: usize = 0;
        for (0..self.total_pages) |pfn| {
            const byte_idx = pfn / 8;
            const bit_idx: u3 = @intCast(pfn % 8);
            if ((self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) == 0) {
                bitmap_free += 1;
            }
        }

        return bitmap_free == self.free_count;
    }
};

test "alloc and free single page" {
    var alloc = TestAllocator{};
    alloc.init();

    const expect = std.testing.expect;

    // Initial state
    try expect(alloc.free_count == TestAllocator.NUM_PAGES);
    try expect(alloc.allocatedCount() == 0);

    // Allocate
    const page = alloc.allocPage();
    try expect(page != null);
    try expect(alloc.free_count == TestAllocator.NUM_PAGES - 1);
    try expect(alloc.allocatedCount() == 1);

    // Free
    alloc.freePage(page.?);
    try expect(alloc.free_count == TestAllocator.NUM_PAGES);
    try expect(alloc.allocatedCount() == 0);
}

test "alloc all pages then free all" {
    var alloc = TestAllocator{};
    alloc.init();

    const expect = std.testing.expect;
    var allocated: [TestAllocator.NUM_PAGES]usize = undefined;

    // Allocate all
    for (0..TestAllocator.NUM_PAGES) |i| {
        const page = alloc.allocPage();
        try expect(page != null);
        allocated[i] = page.?;
    }

    try expect(alloc.free_count == 0);
    try expect(alloc.allocatedCount() == TestAllocator.NUM_PAGES);

    // Next alloc should fail
    try expect(alloc.allocPage() == null);

    // Free all
    for (allocated) |addr| {
        alloc.freePage(addr);
    }

    try expect(alloc.free_count == TestAllocator.NUM_PAGES);
    try expect(alloc.allocatedCount() == 0);
}

test "alloc-free-alloc reuses pages (LIFO)" {
    var alloc = TestAllocator{};
    alloc.init();

    const expect = std.testing.expect;

    const page1 = alloc.allocPage().?;
    alloc.freePage(page1);
    const page2 = alloc.allocPage().?;

    // LIFO: should get same page back
    try expect(page1 == page2);

    alloc.freePage(page2);
}

test "verify integrity after operations" {
    var alloc = TestAllocator{};
    alloc.init();

    const expect = std.testing.expect;

    try expect(alloc.verifyIntegrity());

    const p1 = alloc.allocPage().?;
    const p2 = alloc.allocPage().?;
    const p3 = alloc.allocPage().?;
    try expect(alloc.verifyIntegrity());

    alloc.freePage(p2);
    try expect(alloc.verifyIntegrity());

    alloc.freePage(p1);
    alloc.freePage(p3);
    try expect(alloc.verifyIntegrity());
}

test "pages are properly aligned" {
    var alloc = TestAllocator{};
    alloc.init();

    const expect = std.testing.expect;

    for (0..TestAllocator.NUM_PAGES) |_| {
        const page = alloc.allocPage().?;
        try expect(page & (PAGE_SIZE - 1) == 0);
    }
}

test "allocated pages are within region bounds" {
    var alloc = TestAllocator{};
    alloc.init();

    const expect = std.testing.expect;
    const region_end = alloc.base_addr + TestAllocator.MEM_SIZE;

    for (0..TestAllocator.NUM_PAGES) |_| {
        const page = alloc.allocPage().?;
        try expect(page >= alloc.base_addr);
        try expect(page < region_end);
    }
}
