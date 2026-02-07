//! ARM64 Memory Management Unit.
//!
//! ARM64 uses a two-register design for address translation: TTBR0 handles the lower
//! half of the virtual address space (user), TTBR1 handles the upper half (kernel).
//! The split allows fast context switches — only TTBR0 changes when switching
//! processes, while TTBR1 stays fixed for the kernel.
//!
//! We configure 39-bit virtual addresses (T0SZ=T1SZ=25) with 4KB pages, giving us a
//! 3-level page table walk (L1 -> L2 -> L3). Boot uses 1GB blocks at L1 to avoid
//! allocating L2/L3 tables.
//!
//! ARM calls page table entries "descriptors" but we use "PageTableEntry" to match OS literature.
//!
//! See ARM Architecture Reference Manual, Chapter D8 (The AArch64 Virtual Memory
//! System Architecture).
//!
//! TODO(smp): Implement per-CPU page table locks.
//! TODO(smp): Use ASID for per-process TLB management (currently ASID=0).

const std = @import("std");
const cpu = @import("cpu.zig");

const memory = @import("../../memory/memory.zig");
const mmu_types = @import("../../mmu/mmu.zig");

const PAGE_SIZE = memory.PAGE_SIZE;
const PAGE_SHIFT = memory.PAGE_SHIFT;
const ENTRIES_PER_TABLE = memory.ENTRIES_PER_TABLE;
const DTB_MAX_SIZE = memory.DTB_MAX_SIZE;
const MIN_PHYSMAP_SIZE = memory.MIN_PHYSMAP_SIZE;
const PageFlags = mmu_types.PageFlags;
const MapError = mmu_types.MapError;
const UnmapError = mmu_types.UnmapError;

/// Kernel virtual base address (39-bit VA upper half, TTBR1 region).
/// Physical addresses are mapped to virtual = physical + KERNEL_VIRT_BASE.
/// With T1SZ=25 (39-bit VA), TTBR1 handles addresses where bits 63:39 are all 1s.
pub const KERNEL_VIRT_BASE: usize = 0xFFFF_FF80_0000_0000;

/// Offset from KERNEL_VIRT_BASE for kernel stack region.
/// Must be beyond physmap (RAM). 8GB offset supports systems up to 8GB RAM.
/// Each stack slot is 12KB; 256 threads need ~3MB of VA space.
pub const KSTACK_REGION_OFFSET: usize = 8 * (1 << 30); // 8GB

const BLOCK_1GB_SIZE: usize = 1 << 30;
const BLOCK_1GB_MASK: usize = BLOCK_1GB_SIZE - 1;
const BLOCK_2MB_SIZE: usize = 1 << 21;
const BLOCK_2MB_MASK: usize = BLOCK_2MB_SIZE - 1;

/// Convert physical address to kernel virtual address.
pub inline fn physToVirt(paddr: usize) usize {
    return paddr +% KERNEL_VIRT_BASE;
}

/// Convert kernel virtual address to physical address.
pub inline fn virtToPhys(vaddr: usize) usize {
    return vaddr -% KERNEL_VIRT_BASE;
}

/// Memory type for MAIR_EL1 indexing in PTEs.
pub const MemoryAttribute = enum(u3) {
    device_nGnRnE = 0,
    device_nGnRE = 1,
    normal_nc = 2,
    normal_wbwa = 3,
    normal_tagged = 4,
};

/// MAIR_EL1 memory attribute encodings for AttrIndx field in PTEs.
const MAIR_VALUE: u64 =
    (@as(u64, 0x00) << 0) | // 0: Device nGnRnE (strongly ordered)
    (@as(u64, 0x04) << 8) | // 1: Device nGnRE (non-reordering)
    (@as(u64, 0x44) << 16) | // 2: Normal Non-Cacheable
    (@as(u64, 0xFF) << 24) | // 3: Normal Write-Back Write-Allocate
    (@as(u64, 0xF0) << 32); // 4: Normal Tagged

/// Shareability domain for cache coherency.
/// Inner shareable = coherent within cluster (typical for multicore).
/// Device memory uses outer shareable per ARM recommendations.
pub const Shareability = enum(u2) {
    non_shareable = 0b00,
    outer_shareable = 0b10,
    inner_shareable = 0b11,
};

/// Page table descriptor. Same layout for L1/L2/L3; type determined by level and bits.
pub const PageTableEntry = packed struct(u64) {
    valid: bool = false,
    type_bit: bool = false, // 0=block, 1=table/page
    attr_idx: u3 = 0,
    ns: bool = false,
    ap1: bool = false, // User access
    ap2: bool = false, // Read-only
    sh: Shareability = .non_shareable,
    af: bool = false, // Access flag
    ng: bool = false, // Non-global (per-ASID)
    output_addr: u36 = 0,
    reserved1: u4 = 0,
    cont: bool = false,
    pxn: bool = false, // Privileged execute never
    uxn: bool = false, // User execute never
    sw_bits: u4 = 0,
    reserved2: u5 = 0,

    pub const INVALID = PageTableEntry{};

    pub inline fn isValid(self: PageTableEntry) bool {
        return self.valid;
    }

    /// Check if this is a table entry (pointer to next level).
    pub inline fn isTable(self: PageTableEntry) bool {
        return self.valid and self.type_bit;
    }

    /// Check if this is a block entry (1GB or 2MB mapping).
    pub inline fn isBlock(self: PageTableEntry) bool {
        return self.valid and !self.type_bit;
    }

    pub inline fn physAddr(self: PageTableEntry) usize {
        return @as(usize, self.output_addr) << PAGE_SHIFT;
    }

    /// Create table entry pointing to next level page table.
    pub fn table(next_table_phys: usize) PageTableEntry {
        return .{ .valid = true, .type_bit = true, .output_addr = @truncate(next_table_phys >> PAGE_SHIFT) };
    }

    /// Create kernel block entry (1GB or 2MB). All valid mappings are implicitly readable.
    pub fn kernelBlock(phys_addr: usize, write: bool, exec: bool) PageTableEntry {
        return .{
            .valid = true,
            .attr_idx = @intFromEnum(MemoryAttribute.normal_wbwa),
            .ap2 = !write,
            .sh = .inner_shareable,
            .af = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = !exec,
            .uxn = true,
        };
    }

    pub fn deviceBlock(phys_addr: usize) PageTableEntry {
        return .{
            .valid = true,
            .attr_idx = @intFromEnum(MemoryAttribute.device_nGnRnE),
            .sh = .outer_shareable,
            .af = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = true,
            .uxn = true,
        };
    }

    /// Create kernel page entry (4KB). All valid mappings are implicitly readable.
    pub fn kernelPage(phys_addr: usize, write: bool, exec: bool) PageTableEntry {
        return .{
            .valid = true,
            .type_bit = true,
            .attr_idx = @intFromEnum(MemoryAttribute.normal_wbwa),
            .ap2 = !write,
            .sh = .inner_shareable,
            .af = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = !exec,
            .uxn = true,
        };
    }

    /// Create user page entry (4KB). Sets non-global bit for per-ASID TLB invalidation.
    pub fn userPage(phys_addr: usize, write: bool, exec: bool) PageTableEntry {
        return .{
            .valid = true,
            .type_bit = true,
            .attr_idx = @intFromEnum(MemoryAttribute.normal_wbwa),
            .ap1 = true,
            .ap2 = !write,
            .sh = .inner_shareable,
            .af = true,
            .ng = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = true,
            .uxn = !exec,
        };
    }
};

comptime {
    if (@sizeOf(PageTableEntry) != 8) @compileError("PageTableEntry must be 8 bytes");
}

/// Page table containing 512 entries (one 4KB page).
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PageTableEntry,

    pub const EMPTY = PageTable{ .entries = [_]PageTableEntry{PageTableEntry.INVALID} ** ENTRIES_PER_TABLE };

    pub inline fn get(self: *const PageTable, index: usize) PageTableEntry {
        return self.entries[index];
    }

    pub inline fn set(self: *PageTable, index: usize, desc: PageTableEntry) void {
        self.entries[index] = desc;
    }
};

comptime {
    if (@sizeOf(PageTable) != PAGE_SIZE) @compileError("PageTable must be one page");
}

/// 39-bit VA parsing (T0SZ=25/T1SZ=25, no L0).
/// TTBR0 handles addresses 0x0000_0000_0000_0000 to 0x0000_007F_FFFF_FFFF (bits 63:39 = 0).
/// TTBR1 handles addresses 0xFFFF_FF80_0000_0000 to 0xFFFF_FFFF_FFFF_FFFF (bits 63:39 = 1).
pub const VirtualAddress = struct {
    l1: u9, // Bits 38:30
    l2: u9, // Bits 29:21
    l3: u9, // Bits 20:12
    offset: u12,

    pub inline fn parse(vaddr: usize) VirtualAddress {
        return .{
            .l1 = @truncate((vaddr >> 30) & 0x1FF),
            .l2 = @truncate((vaddr >> 21) & 0x1FF),
            .l3 = @truncate((vaddr >> 12) & 0x1FF),
            .offset = @truncate(vaddr & 0xFFF),
        };
    }

    /// Check if address is in TTBR0 range (user space, low addresses 0 to 512GB).
    pub inline fn isUserRange(vaddr: usize) bool {
        return vaddr < (1 << 39);
    }

    /// Check if address is valid for TTBR1 (kernel space, high addresses).
    pub inline fn isKernel(vaddr: usize) bool {
        return (vaddr & KERNEL_VIRT_BASE) == KERNEL_VIRT_BASE;
    }

    /// Check if address is in valid range (either TTBR0 or TTBR1).
    pub inline fn isCanonical(vaddr: usize) bool {
        return isUserRange(vaddr) or isKernel(vaddr);
    }
};

pub const TranslationControlRegister = struct {
    /// TCR_EL1: T0SZ=25 (39-bit VA), 4KB granule, both TTBR0 and TTBR1 enabled.
    pub fn build() u64 {
        var tcr: u64 = 0;
        tcr |= 25; // T0SZ - 39-bit VA for TTBR0
        tcr |= (0b01 << 8); // IRGN0 write-back
        tcr |= (0b01 << 10); // ORGN0 write-back
        tcr |= (0b10 << 12); // SH0 inner shareable
        tcr |= (0b00 << 14); // TG0 4KB granule
        tcr |= (25 << 16); // T1SZ - 39-bit VA for TTBR1
        tcr |= (0b01 << 24); // IRGN1 write-back
        tcr |= (0b01 << 26); // ORGN1 write-back
        tcr |= (0b10 << 28); // SH1 inner shareable
        tcr |= (@as(u64, 0b10) << 30); // TG1 4KB granule
        tcr |= (@as(u64, 0b010) << 32); // IPS 40-bit PA
        return tcr;
    }

    pub const DEFAULT: u64 = build();

    pub fn read() u64 {
        return asm volatile ("mrs %[ret], tcr_el1"
            : [ret] "=r" (-> u64),
        );
    }

    pub fn write(value: u64) void {
        asm volatile ("msr tcr_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

const SystemControlRegister = struct {
    fn enableMmu() void {
        var sctlr: u64 = asm volatile ("mrs %[ret], sctlr_el1"
            : [ret] "=r" (-> u64),
        );
        sctlr |= 1;
        asm volatile ("msr sctlr_el1, %[val]"
            :
            : [val] "r" (sctlr),
        );
        instructionBarrier();
    }
};

/// Data barrier ensures stores complete before TLB invalidation.
inline fn storeBarrier() void {
    cpu.dataSyncBarrierIshst();
}

inline fn fullBarrier() void {
    cpu.dataSyncBarrierIsh();
}

/// Flushes pipeline after MMU configuration changes.
inline fn instructionBarrier() void {
    cpu.instructionBarrier();
}

inline fn tlbFlushAll() void {
    asm volatile ("tlbi alle1is");
}

inline fn tlbFlushLocal() void {
    asm volatile ("tlbi vmalle1");
}

// TODO(smp): After secondary cores are online, always use broadcast (flushAll).
// During boot, use flushLocal() since secondary cores aren't initialized.
pub const TranslationLookasideBuffer = struct {
    /// Invalidate all TLB entries (broadcasts to inner shareable domain).
    /// Use after SMP init when all cores are running.
    pub inline fn flushAll() void {
        storeBarrier();
        tlbFlushAll();
        fullBarrier();
        instructionBarrier();
    }

    /// Invalidate cached translation for a specific virtual address (broadcasts).
    pub inline fn flushAddr(vaddr: usize) void {
        const va_operand = (vaddr >> 12) & 0xFFFFFFFFFFF;
        storeBarrier();
        asm volatile ("tlbi vale1is, %[va]"
            :
            : [va] "r" (va_operand),
        );
        fullBarrier();
        instructionBarrier();
    }

    /// Invalidate TLB on this core only (no broadcast).
    /// Use during boot when secondary cores aren't initialized.
    pub inline fn flushLocal() void {
        storeBarrier();
        tlbFlushLocal();
        fullBarrier();
        instructionBarrier();
    }

    /// Invalidate all cached translations for a specific address space.
    /// TODO(smp): Use this for efficient process teardown with ASID.
    pub fn flushAsid(asid: u16) void {
        const operand = @as(u64, asid) << 48;
        storeBarrier();
        asm volatile ("tlbi aside1is, %[asid]"
            :
            : [asid] "r" (operand),
        );
        fullBarrier();
        instructionBarrier();
    }

    /// Invalidate cached translation for a specific virtual address and address space.
    pub fn flushAddrAsid(vaddr: usize, asid: u16) void {
        const va_bits = (vaddr >> 12) & 0xFFFFFFFFFFF;
        const operand = (@as(u64, asid) << 48) | va_bits;
        storeBarrier();
        asm volatile ("tlbi vae1is, %[op]"
            :
            : [op] "r" (operand),
        );
        fullBarrier();
        instructionBarrier();
    }
};

// TODO(smp): These functions modify page tables and need external locking.
// Caller must hold appropriate lock before calling mapPage/unmapPage.

/// Walk page tables for a virtual address and return pointer to the leaf entry.
/// Returns null if any level has an invalid entry or if a block mapping is found
/// before reaching L3. Only walks to L3 (4KB page) level.
pub fn walk(root: *PageTable, vaddr: usize) ?*PageTableEntry {
    if (!VirtualAddress.isCanonical(vaddr)) return null;

    const va = VirtualAddress.parse(vaddr);

    // Level 1
    const l1_entry = &root.entries[va.l1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isBlock()) return null; // 1GB block, not page-level

    // Level 2
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l2_entry = &l2_table.entries[va.l2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isBlock()) return null; // 2MB block, not page-level

    // Level 3
    const l3_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    return &l3_table.entries[va.l3];
}

/// Translate virtual address to physical address.
/// Handles block mappings at any level as well as page mappings.
/// Returns null if address is not mapped.
pub fn translate(root: *PageTable, vaddr: usize) ?usize {
    if (!VirtualAddress.isCanonical(vaddr)) return null;

    const va = VirtualAddress.parse(vaddr);

    // Level 1
    const l1_entry = root.entries[va.l1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isBlock()) {
        return l1_entry.physAddr() | (vaddr & BLOCK_1GB_MASK);
    }

    // Level 2
    const l2_table: *const PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l2_entry = l2_table.entries[va.l2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isBlock()) {
        return l2_entry.physAddr() | (vaddr & BLOCK_2MB_MASK);
    }

    // Level 3
    const l3_table: *const PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l3_entry = l3_table.entries[va.l3];
    if (!l3_entry.isValid()) return null;

    return l3_entry.physAddr() | @as(usize, va.offset);
}

/// Map a 4KB page at the given virtual address.
/// Requires all intermediate page tables (L1, L2) to already exist.
/// Does NOT flush TLB - caller must do that after mapping.
/// TODO(smp): Caller must hold page table lock.
pub fn mapPage(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags) MapError!void {
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtualAddress.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtualAddress.parse(vaddr);

    // Level 1 - must be a table entry
    const l1_entry = root.entries[va.l1];
    if (!l1_entry.isValid()) return MapError.TableNotPresent;
    if (!l1_entry.isTable()) return MapError.SuperpageConflict;

    // Level 2 - must be a table entry
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l2_entry = l2_table.entries[va.l2];
    if (!l2_entry.isValid()) return MapError.TableNotPresent;
    if (!l2_entry.isTable()) return MapError.SuperpageConflict;

    // Level 3 - the actual page entry
    const l3_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l3_entry = &l3_table.entries[va.l3];
    if (l3_entry.isValid()) return MapError.AlreadyMapped;

    if (flags.user) {
        l3_entry.* = PageTableEntry.userPage(paddr, flags.write, flags.exec);
    } else {
        l3_entry.* = PageTableEntry.kernelPage(paddr, flags.write, flags.exec);
    }
    storeBarrier();
}

/// Function type for page table allocation.
/// Must return virtual address of a zeroed page, or null on OOM.
pub const PageAllocFn = *const fn () ?usize;

/// Map a 4KB page, allocating intermediate tables as needed.
/// alloc_page must return virtual address of a zeroed page.
/// Does NOT flush TLB - caller must do that after mapping.
/// TODO(smp): Caller must hold page table lock.
pub fn mapPageWithAlloc(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags, alloc_page: PageAllocFn) MapError!void {
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtualAddress.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtualAddress.parse(vaddr);

    // Level 1 - allocate L2 table if needed
    var l1_entry = &root.entries[va.l1];
    if (!l1_entry.isValid()) {
        const l2_virt = alloc_page() orelse return MapError.OutOfMemory;
        l1_entry.* = PageTableEntry.table(virtToPhys(l2_virt));
        storeBarrier();
    } else if (!l1_entry.isTable()) {
        return MapError.SuperpageConflict;
    }

    // Level 2 - allocate L3 table if needed
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    var l2_entry = &l2_table.entries[va.l2];
    if (!l2_entry.isValid()) {
        const l3_virt = alloc_page() orelse return MapError.OutOfMemory;
        l2_entry.* = PageTableEntry.table(virtToPhys(l3_virt));
        storeBarrier();
    } else if (!l2_entry.isTable()) {
        return MapError.SuperpageConflict;
    }

    // Level 3 - the actual page entry
    const l3_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l3_entry = &l3_table.entries[va.l3];
    if (l3_entry.isValid()) return MapError.AlreadyMapped;

    if (flags.user) {
        l3_entry.* = PageTableEntry.userPage(paddr, flags.write, flags.exec);
    } else {
        l3_entry.* = PageTableEntry.kernelPage(paddr, flags.write, flags.exec);
    }
    storeBarrier();
}

/// Unmap a 4KB page at the given virtual address.
/// Returns the physical address that was mapped.
/// Does NOT flush TLB - caller must do that after unmapping (allows batching).
/// TODO(smp): Caller must hold page table lock.
pub fn unmapPage(root: *PageTable, vaddr: usize) UnmapError!usize {
    if (!VirtualAddress.isCanonical(vaddr)) return UnmapError.NotCanonical;

    const entry = walk(root, vaddr) orelse return UnmapError.NotMapped;
    if (!entry.isValid()) return UnmapError.NotMapped;

    const paddr = entry.physAddr();
    entry.* = PageTableEntry.INVALID;
    storeBarrier();
    return paddr;
}

/// Unmap a 4KB page and immediately flush TLB for that address.
/// Convenience wrapper when batching is not needed.
pub fn unmapPageAndFlush(root: *PageTable, vaddr: usize) UnmapError!usize {
    const paddr = try unmapPage(root, vaddr);
    TranslationLookasideBuffer.flushAddr(vaddr);
    return paddr;
}

var l1_table_low: PageTable align(PAGE_SIZE) = PageTable.EMPTY;
var l1_table_high: PageTable align(PAGE_SIZE) = PageTable.EMPTY;

/// Maximum L1 index for physmap (512 entries, 0-511).
/// With 39-bit VA (T1SZ=25), TTBR1 maps up to 512GB.
const MAX_PHYSMAP_ENTRIES: usize = ENTRIES_PER_TABLE;

var stored_kernel_phys_load: usize = 0;
var physmap_end_gb: usize = 0;

/// Set up identity + higher-half mappings using 1GB blocks, enable MMU.
/// Creates minimal mapping covering kernel and DTB. Call expandPhysmap()
/// after reading DTB to map remaining RAM.
/// Called from physInit() on primary core before SMP.
pub fn init(kernel_phys_load: usize, dtb_ptr: usize) void {
    stored_kernel_phys_load = kernel_phys_load;

    asm volatile ("msr mair_el1, %[mair]"
        :
        : [mair] "r" (MAIR_VALUE),
    );
    instructionBarrier();

    TranslationControlRegister.write(TranslationControlRegister.DEFAULT);
    instructionBarrier();

    // Calculate mapping to cover both kernel and DTB
    const map_start = if (dtb_ptr > 0) @min(kernel_phys_load, dtb_ptr) else kernel_phys_load;
    const dtb_end = if (dtb_ptr > 0) dtb_ptr + DTB_MAX_SIZE else kernel_phys_load;
    const map_end = @max(kernel_phys_load + MIN_PHYSMAP_SIZE, dtb_end);
    const start_gb = map_start >> 30;
    const end_gb = (map_end + (1 << 30) - 1) >> 30;
    physmap_end_gb = end_gb;

    // TTBR0: Identity mapping (for boot continuation after MMU enable)
    l1_table_low.entries[0] = PageTableEntry.deviceBlock(0); // MMIO (first GB)

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l1_table_low.entries[gb] = PageTableEntry.kernelBlock(gb << 30, true, true);
    }

    // TTBR1: Higher-half kernel mapping
    l1_table_high.entries[0] = PageTableEntry.deviceBlock(0); // MMIO in higher-half

    gb = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l1_table_high.entries[gb] = PageTableEntry.kernelBlock(gb << 30, true, true);
    }

    // Set both translation table base registers
    asm volatile ("msr ttbr0_el1, %[ttbr]"
        :
        : [ttbr] "r" (@intFromPtr(&l1_table_low)),
    );
    asm volatile ("msr ttbr1_el1, %[ttbr]"
        :
        : [ttbr] "r" (@intFromPtr(&l1_table_high)),
    );
    instructionBarrier();

    // Use local TLBI before MMU enable (broadcast can fault when MMU is off)
    TranslationLookasideBuffer.flushLocal();

    SystemControlRegister.enableMmu();
}

/// Expand physmap to cover all RAM. Called after DTB is readable.
/// Uses 1GB blocks - no page allocation needed, just L1 entries.
/// Called from virtInit() on primary core before SMP.
pub fn expandPhysmap(ram_size: usize) void {
    const new_end = stored_kernel_phys_load + ram_size;
    const new_end_gb = @min((new_end + (1 << 30) - 1) >> 30, MAX_PHYSMAP_ENTRIES);

    var gb = physmap_end_gb;
    while (gb < new_end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l1_table_high.entries[gb] = PageTableEntry.kernelBlock(gb << 30, true, true);
    }

    if (new_end_gb > physmap_end_gb) {
        TranslationLookasideBuffer.flushLocal(); // Local only - secondary cores not running yet
        physmap_end_gb = new_end_gb;
    }
}

/// Disable MMU. Only safe if running from identity-mapped region.
pub fn disable() void {
    var sctlr: u64 = asm volatile ("mrs %[ret], sctlr_el1"
        : [ret] "=r" (-> u64),
    );
    sctlr &= ~@as(u64, 1);
    asm volatile ("msr sctlr_el1, %[val]"
        :
        : [val] "r" (sctlr),
    );
    instructionBarrier();
    TranslationLookasideBuffer.flushAll();
}

/// Return pointer to kernel page table (L1 for TTBR1).
/// Used for mapping kernel stack pages with guard pages.
pub fn getKernelPageTable() *PageTable {
    return &l1_table_high;
}

/// Remove identity mapping after transitioning to higher-half.
/// Improves security by preventing kernel access via low addresses.
/// Called from virtInit() on primary core before SMP.
pub fn removeIdentityMapping() void {
    const start_gb = stored_kernel_phys_load >> 30;
    const end_gb = physmap_end_gb;

    l1_table_low.entries[0] = PageTableEntry.INVALID; // Clear MMIO identity mapping

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        l1_table_low.entries[gb] = PageTableEntry.INVALID;
    }

    TranslationLookasideBuffer.flushLocal();
}

/// Post-MMU initialization for ARM64. No-op since ARM64 doesn't need
/// register adjustments after switching to virtual addresses.
pub fn postMmuInit() void {}

test "validates PageTableEntry size and layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PageTableEntry));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(PageTableEntry));
}

test "sets PageTableEntry.INVALID to all zeros" {
    const invalid: u64 = @bitCast(PageTableEntry.INVALID);
    try std.testing.expectEqual(@as(u64, 0), invalid);
}

test "creates valid PageTableEntry.table entry" {
    const desc = PageTableEntry.table(0x80000000);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.isTable());
    try std.testing.expect(!desc.isBlock());
    try std.testing.expectEqual(@as(usize, 0x80000000), desc.physAddr());
}

test "creates valid PageTableEntry.kernelBlock entry" {
    const desc = PageTableEntry.kernelBlock(0x40000000, true, true);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.isBlock());
    try std.testing.expect(!desc.ng);
    try std.testing.expect(desc.af);
}

test "sets correct attributes for PageTableEntry.deviceBlock" {
    const desc = PageTableEntry.deviceBlock(0x09000000);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.isBlock());
    try std.testing.expectEqual(@intFromEnum(MemoryAttribute.device_nGnRnE), desc.attr_idx);
    try std.testing.expect(desc.pxn);
    try std.testing.expect(desc.uxn);
}

test "creates non-global PageTableEntry.userPage entry" {
    const desc = PageTableEntry.userPage(0x1000, true, false);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.ng);
    try std.testing.expect(desc.ap1);
    try std.testing.expect(desc.uxn);
}

test "extracts correct indices in VirtualAddress.parse" {
    const va = VirtualAddress.parse(0x40080000);
    try std.testing.expectEqual(@as(u9, 1), va.l1);
    try std.testing.expectEqual(@as(u9, 0), va.l2);
    try std.testing.expectEqual(@as(u9, 128), va.l3);
    try std.testing.expectEqual(@as(u12, 0), va.offset);
}

test "detects TTBR0 user range in VirtualAddress.isUserRange" {
    try std.testing.expect(VirtualAddress.isUserRange(0x0000_0000_0000_0000));
    try std.testing.expect(VirtualAddress.isUserRange(0x0000_007F_FFFF_FFFF));
    try std.testing.expect(!VirtualAddress.isUserRange(0x0000_0080_0000_0000));
}

test "detects TTBR1 kernel addresses in VirtualAddress.isKernel" {
    try std.testing.expect(VirtualAddress.isKernel(0xFFFF_FF80_0000_0000));
    try std.testing.expect(VirtualAddress.isKernel(0xFFFF_FFFF_FFFF_FFFF));
    try std.testing.expect(VirtualAddress.isKernel(KERNEL_VIRT_BASE));
    try std.testing.expect(!VirtualAddress.isKernel(0x0000_0000_0000_0000));
    try std.testing.expect(!VirtualAddress.isKernel(0x0000_007F_FFFF_FFFF));
}

test "accepts both ranges in VirtualAddress.isCanonical" {
    try std.testing.expect(VirtualAddress.isCanonical(0x0000_0000_0000_0000));
    try std.testing.expect(VirtualAddress.isCanonical(0x0000_007F_FFFF_FFFF));
    try std.testing.expect(VirtualAddress.isCanonical(0xFFFF_FF80_0000_0000));
    try std.testing.expect(VirtualAddress.isCanonical(0xFFFF_FFFF_FFFF_FFFF));
    try std.testing.expect(!VirtualAddress.isCanonical(0x0000_0080_0000_0000));
    try std.testing.expect(!VirtualAddress.isCanonical(0x8000_0000_0000_0000));
}

test "matches PageTable size to page size" {
    try std.testing.expectEqual(PAGE_SIZE, @sizeOf(PageTable));
}

test "produces valid TranslationControlRegister.DEFAULT configuration" {
    const tcr = TranslationControlRegister.DEFAULT;
    try std.testing.expectEqual(@as(u64, 25), tcr & 0x3F);
    try std.testing.expectEqual(@as(u64, 25), (tcr >> 16) & 0x3F);
    try std.testing.expectEqual(@as(u64, 0b10), (tcr >> 12) & 0x3);
}

test "translates 1GB block mappings" {
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelBlock(0x40000000, true, true);

    const pa = translate(&root, 0x40123456);
    try std.testing.expectEqual(@as(?usize, 0x40123456), pa);
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x80000000));
}

test "returns null for non-canonical addresses in translate" {
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelBlock(0x40000000, true, true);
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x0000_0080_0000_0000));
}

test "returns NotAligned for misaligned addresses in mapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1001, 0x2000, .{}));
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1000, 0x2001, .{}));
}

test "returns NotCanonical for non-canonical addresses in mapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x0000_0080_0000_0000, 0x1000, .{}));
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x8000_0000_0000_0000, 0x1000, .{}));
}

test "returns SuperpageConflict for block mappings in mapPage" {
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelBlock(0x40000000, true, true);
    try std.testing.expectError(MapError.SuperpageConflict, mapPage(&root, 0x40001000, 0x80001000, .{}));
}

test "returns TableNotPresent without intermediate tables in mapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.TableNotPresent, mapPage(&root, 0x40001000, 0x80001000, .{}));
}

test "returns null for unmapped address in walk" {
    var root = PageTable.EMPTY;
    try std.testing.expectEqual(@as(?*PageTableEntry, null), walk(&root, 0x40001000));
}

test "returns null for block mapping in walk" {
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelBlock(0x40000000, true, true);
    try std.testing.expectEqual(@as(?*PageTableEntry, null), walk(&root, 0x40001000));
}

test "adds KERNEL_VIRT_BASE in physToVirt" {
    const virt = physToVirt(0x40080000);
    try std.testing.expectEqual(@as(usize, 0xFFFF_FF80_4008_0000), virt);
}

test "subtracts KERNEL_VIRT_BASE in virtToPhys" {
    const phys = virtToPhys(0xFFFF_FF80_4008_0000);
    try std.testing.expectEqual(@as(usize, 0x40080000), phys);
}

test "treats physToVirt and virtToPhys as inverses" {
    const original: usize = 0x40080000;
    const round_trip = virtToPhys(physToVirt(original));
    try std.testing.expectEqual(original, round_trip);
}

test "returns NotMapped for unmapped address in unmapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(UnmapError.NotMapped, unmapPage(&root, 0x40001000));
}

test "returns NotCanonical for non-canonical addresses in unmapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(UnmapError.NotCanonical, unmapPage(&root, 0x0000_0080_0000_0000));
}
