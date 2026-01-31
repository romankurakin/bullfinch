//! Kernel Stack Allocator.
//!
//! Manages kernel stacks in a dedicated virtual address region with guard pages.
//! Each 12KB slot contains a 4KB unmapped guard page followed by 8KB of mapped
//! stack. Stack overflow hits the guard, causing a page fault instead of silent
//! memory corruption.
//!
//! Slot allocation uses a monotonic counter. With 512GB kernel VA and 12KB slots,
//! approximately 42 million slots are available.
//!
//! TODO(smp): Add page table lock for concurrent create/destroy.
//! TODO(smp): Use TLB shootdown (IPI) instead of flushLocal.
//! TODO(security): Add shadow call stack for ROP protection once IPC exists.

const hal = @import("../hal/hal.zig");
const memory = @import("../memory/memory.zig");
const pmm = @import("../pmm/pmm.zig");

const PAGE_SIZE = memory.PAGE_SIZE;
const GUARD_SIZE = memory.GUARD_SIZE;
const SLOT_SIZE = memory.KSTACK_SLOT_SIZE;
const STACK_PAGES = (SLOT_SIZE - GUARD_SIZE) / PAGE_SIZE;

pub const REGION_BASE: usize = hal.mmu.KERNEL_VIRT_BASE +% hal.mmu.KSTACK_REGION_OFFSET;

/// Maximum slots before VA space exhaustion. 512GB / 12KB ≈ 42 million.
const MAX_SLOTS: usize = (512 * 1024 * 1024 * 1024) / SLOT_SIZE;

var next_slot: usize = 0;

/// Initialize stack subsystem. Call after PMM init.
pub fn init() void {
    // Nothing to initialize - kept for API compatibility.
}

pub const Stack = struct {
    base: [*]u8,
    size: usize,
    phys: *pmm.Page,

    pub fn create() ?Stack {
        const slot = @atomicRmw(usize, &next_slot, .Add, 1, .monotonic);
        if (slot >= MAX_SLOTS) return null;

        const stack_base = REGION_BASE + (slot * SLOT_SIZE) + GUARD_SIZE;
        const phys = pmm.allocContiguous(STACK_PAGES, 0) orelse return null;

        var i: usize = 0;
        while (i < STACK_PAGES) : (i += 1) {
            const vaddr = stack_base + i * PAGE_SIZE;
            const paddr = pmm.pageToPhys(pmm.pageAdd(phys, i));
            hal.mmu.mapPageWithAlloc(
                hal.mmu.getKernelPageTable(),
                vaddr,
                paddr,
                .{ .write = true, .exec = false, .user = false },
                allocPageTable,
            ) catch {
                // Rollback mapped pages. Intermediate page tables may leak.
                // TODO(oom): Track and free page tables allocated during this call.
                while (i > 0) {
                    i -= 1;
                    _ = hal.mmu.unmapPage(hal.mmu.getKernelPageTable(), stack_base + i * PAGE_SIZE) catch {};
                }
                hal.mmu.TranslationLookasideBuffer.flushLocal();
                pmm.freeContiguous(phys, STACK_PAGES) catch {};
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
            _ = hal.mmu.unmapPage(pt, base + i * PAGE_SIZE) catch {};
        }

        hal.mmu.TranslationLookasideBuffer.flushLocal();
        pmm.freeContiguous(self.phys, STACK_PAGES) catch {};
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
