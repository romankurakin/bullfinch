//! Kernel debugging and diagnostics utilities.
//!
//! Provides inspection tools for memory, allocations, and kernel state.

const console = @import("../console/console.zig");
const pmm = @import("../pmm/pmm.zig");

/// Dump all allocated PMM ranges to console. Call at shutdown to detect leaks.
/// In release builds, only shows summary (no bitmap for range iteration).
pub fn dumpPmmLeaks() void {
    const region_count = pmm.regionCount();
    const total = pmm.totalPages();
    const allocated = pmm.allocatedCount();
    const free = pmm.freeCount();

    console.print("\nPMM Status:");
    console.print(" regions: ");
    console.printDec(region_count);
    console.print(", total: ");
    console.printDec(total);
    console.print(" pages, allocated: ");
    console.printDec(allocated);
    console.print(", free: ");
    console.printDec(free);
    console.print("\n");

    if (!pmm.isDebugEnabled()) {
        console.print("Allocated range tracking disabled in release\n");
        return;
    }

    if (allocated == 0) {
        console.print("no allocations (clean)\n");
        return;
    }

    console.print("Allocated ranges:\n");
    var ranges = pmm.allocatedRanges();
    var range_count: usize = 0;
    while (ranges.next()) |range| {
        console.printHex(range.base);
        console.print(" - ");
        console.printHex(range.base + range.pages * 0x1000);
        console.print(" (");
        console.printDec(range.pages);
        console.print(" pages)\n");
        range_count += 1;
    }
    console.print("total: ");
    console.printDec(range_count);
    console.print(" ranges, ");
    console.printDec(allocated);
    console.print(" pages\n");
}

/// Verify PMM internal consistency.
pub fn verifyPmm() bool {
    const ok = pmm.verifyIntegrity();
    if (ok) {
        console.print("PMM integrity: OK\n");
    } else {
        console.print("PMM integrity: FAILED\n");
    }
    return ok;
}
