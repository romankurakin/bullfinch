//! Kernel Stack Allocator.
//!
//! Manages kernel stacks in a dedicated virtual address region with guard pages.
//! Each 12KB slot contains a 4KB unmapped guard page followed by 8KB of mapped
//! stack. Stack overflow hits the guard, causing a page fault instead of silent
//! memory corruption.
//!
//! Slot allocation uses a monotonic counter. The stack region reserves one 1GB
//! kernel VA slot, giving approximately 87 thousand stack slots.
//!
//! TODO(smp): Add page table lock for concurrent create/destroy.
//! TODO(smp): Use TLB shootdown (IPI) instead of flushLocal.

const hal = @import("../hal/hal.zig");
const memory = @import("../memory/memory.zig");
const pmm = @import("../pmm/pmm.zig");

const PAGE_SIZE = memory.PAGE_SIZE;
const GUARD_SIZE = memory.GUARD_SIZE;
const SLOT_SIZE = memory.KSTACK_SLOT_SIZE;
const STACK_PAGES = (SLOT_SIZE - GUARD_SIZE) / PAGE_SIZE;
const STACK_REGION_SIZE: usize = 1 << 30;

pub const REGION_BASE: usize = hal.mmu.KERNEL_VIRT_BASE +% hal.mmu.KSTACK_REGION_OFFSET;

/// Maximum slots before VA space exhaustion inside the reserved 1GB stack region.
const MAX_SLOTS: usize = STACK_REGION_SIZE / SLOT_SIZE;

const panic_msg = struct {
    const INVALID_PAGE_TABLE = "stack: invalid page table page";
};

var next_slot: usize = 0;

/// Initialize stack subsystem. Call after PMM init.
pub fn init() void {
    // Nothing to initialize - kept for API compatibility.
}

pub const Stack = struct {
    base: [*]u8,
    size: usize,
    phys: []pmm.Page,

    pub fn create() ?Stack {
        const slot = @atomicRmw(usize, &next_slot, .Add, 1, .monotonic);
        if (slot >= MAX_SLOTS) return null;

        const stack_base = REGION_BASE + (slot * SLOT_SIZE) + GUARD_SIZE;
        const phys = pmm.allocContiguous(STACK_PAGES, 0) orelse return null;

        var i: usize = 0;
        while (i < STACK_PAGES) : (i += 1) {
            const vaddr = stack_base + i * PAGE_SIZE;
            const paddr = pmm.pageToPhys(&phys[i]);
            hal.mmu.mapPageWithAlloc(
                hal.mmu.getKernelPageTable(),
                vaddr,
                paddr,
                .{ .write = true, .exec = false, .user = false },
                allocPageTable,
            ) catch {
                // Roll back any mapped pages and reclaim now-empty page tables.
                while (i > 0) {
                    i -= 1;
                    const mapped_vaddr = stack_base + i * PAGE_SIZE;
                    _ = hal.mmu.unmapPage(hal.mmu.getKernelPageTable(), mapped_vaddr) catch {};
                    hal.mmu.reclaimEmptyTables(hal.mmu.getKernelPageTable(), mapped_vaddr, freePageTable);
                }
                hal.mmu.TranslationLookasideBuffer.flushLocal();
                pmm.freeContiguous(phys) catch {};
                return null;
            };
        }

        hal.mmu.TranslationLookasideBuffer.flushLocal();
        return .{ .base = @ptrFromInt(stack_base), .size = STACK_PAGES * PAGE_SIZE, .phys = phys };
    }

    pub fn destroy(self: Stack) void {
        const base = @intFromPtr(self.base);
        const pt = hal.mmu.getKernelPageTable();

        for (0..STACK_PAGES) |i| {
            const vaddr = base + i * PAGE_SIZE;
            _ = hal.mmu.unmapPage(pt, vaddr) catch {};
            hal.mmu.reclaimEmptyTables(pt, vaddr, freePageTable);
        }

        hal.mmu.TranslationLookasideBuffer.flushLocal();
        pmm.freeContiguous(self.phys) catch {};
    }

    pub fn top(self: Stack) usize {
        return @intFromPtr(self.base) + self.size;
    }
};

fn allocPageTable() ?usize {
    const page = pmm.allocPage() orelse return null;
    const virt = hal.mmu.physToVirt(pmm.pageToPhys(page));
    @memset(@as([*]u8, @ptrFromInt(virt))[0..PAGE_SIZE], 0);
    return virt;
}

fn freePageTable(virt: usize) void {
    const phys = hal.mmu.virtToPhys(virt);
    const page = pmm.physToPage(phys) orelse @panic(panic_msg.INVALID_PAGE_TABLE);
    pmm.freePage(page);
}
