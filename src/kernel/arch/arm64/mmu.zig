//! ARM64 Memory Management Unit.
//!
//! ARM64 uses a two-register design for address translation: TTBR0 handles the lower
//! half of the virtual address space (user), TTBR1 handles the upper half (kernel).
//! This differs from RISC-V which uses a single SATP register. The split allows fast
//! context switches — only TTBR0 changes when switching processes, while TTBR1 stays
//! fixed for the kernel.
//!
//! We configure 39-bit virtual addresses (T0SZ=T1SZ=25) with 4KB pages, giving us a
//! 3-level page table walk (L1 -> L2 -> L3). This matches RISC-V Sv39 depth, making
//! the HAL cleaner. Boot uses 1GB blocks at L1 to avoid allocating L2/L3 tables.
//!
//! ARM calls page table entries "descriptors" but we use "Pte" to match OS literature.
//!
//! See ARM Architecture Reference Manual, Chapter D8 (The AArch64 Virtual Memory
//! System Architecture).
//!
//! SMP: Boot functions run on primary core only. mapPage/unmapPage need external locking.
//!
//! TODO(smp): Implement per-CPU page table locks
//! TODO(smp): Use ASID for per-process TLB management (currently ASID=0)

const builtin = @import("builtin");
const std = @import("std");

const kernel = @import("../../kernel.zig");

const is_aarch64 = builtin.cpu.arch == .aarch64;

pub const PAGE_SIZE = kernel.memory.PAGE_SIZE;
pub const PAGE_SHIFT = kernel.memory.PAGE_SHIFT;
pub const ENTRIES_PER_TABLE = kernel.memory.ENTRIES_PER_TABLE;
pub const PageFlags = kernel.mmu.PageFlags;
pub const MapError = kernel.mmu.MapError;
pub const UnmapError = kernel.mmu.UnmapError;

/// Kernel virtual base address (39-bit VA upper half, TTBR1 region).
/// Physical addresses are mapped to virtual = physical + KERNEL_VIRT_BASE.
/// With T1SZ=25 (39-bit VA), TTBR1 handles addresses where bits 63:39 are all 1s.
pub const KERNEL_VIRT_BASE: usize = 0xFFFF_FF80_0000_0000;

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
pub const MemAttr = enum(u3) {
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
pub const Pte = packed struct(u64) {
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

    pub const INVALID = Pte{};

    pub inline fn isValid(self: Pte) bool {
        return self.valid;
    }

    /// Check if this is a table entry (pointer to next level).
    pub inline fn isTable(self: Pte) bool {
        return self.valid and self.type_bit;
    }

    /// Check if this is a block entry (1GB or 2MB mapping).
    pub inline fn isBlock(self: Pte) bool {
        return self.valid and !self.type_bit;
    }

    pub inline fn physAddr(self: Pte) usize {
        return @as(usize, self.output_addr) << PAGE_SHIFT;
    }

    /// Create table entry pointing to next level page table.
    pub fn table(next_table_phys: usize) Pte {
        return .{ .valid = true, .type_bit = true, .output_addr = @truncate(next_table_phys >> PAGE_SHIFT) };
    }

    /// Create kernel block entry (1GB or 2MB). All valid mappings are implicitly readable.
    pub fn kernelBlock(phys_addr: usize, write: bool, exec: bool) Pte {
        return .{
            .valid = true,
            .attr_idx = @intFromEnum(MemAttr.normal_wbwa),
            .ap2 = !write,
            .sh = .inner_shareable,
            .af = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = !exec,
            .uxn = true,
        };
    }

    pub fn deviceBlock(phys_addr: usize) Pte {
        return .{
            .valid = true,
            .attr_idx = @intFromEnum(MemAttr.device_nGnRnE),
            .sh = .outer_shareable,
            .af = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = true,
            .uxn = true,
        };
    }

    /// Create kernel page entry (4KB). All valid mappings are implicitly readable.
    pub fn kernelPage(phys_addr: usize, write: bool, exec: bool) Pte {
        return .{
            .valid = true,
            .type_bit = true,
            .attr_idx = @intFromEnum(MemAttr.normal_wbwa),
            .ap2 = !write,
            .sh = .inner_shareable,
            .af = true,
            .output_addr = @truncate(phys_addr >> PAGE_SHIFT),
            .pxn = !exec,
            .uxn = true,
        };
    }

    /// Create user page entry (4KB). Sets non-global bit for per-ASID TLB invalidation.
    pub fn userPage(phys_addr: usize, write: bool, exec: bool) Pte {
        return .{
            .valid = true,
            .type_bit = true,
            .attr_idx = @intFromEnum(MemAttr.normal_wbwa),
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
    if (@sizeOf(Pte) != 8) @compileError("Pte must be 8 bytes");
}

/// Page table containing 512 entries (one 4KB page).
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]Pte,

    pub const EMPTY = PageTable{ .entries = [_]Pte{Pte.INVALID} ** ENTRIES_PER_TABLE };

    pub inline fn get(self: *const PageTable, index: usize) Pte {
        return self.entries[index];
    }

    pub inline fn set(self: *PageTable, index: usize, desc: Pte) void {
        self.entries[index] = desc;
    }
};

comptime {
    if (@sizeOf(PageTable) != PAGE_SIZE) @compileError("PageTable must be one page");
}

/// 39-bit VA parsing (T0SZ=25/T1SZ=25, no L0).
/// TTBR0 handles addresses 0x0000_0000_0000_0000 to 0x0000_007F_FFFF_FFFF (bits 63:39 = 0).
/// TTBR1 handles addresses 0xFFFF_FF80_0000_0000 to 0xFFFF_FFFF_FFFF_FFFF (bits 63:39 = 1).
pub const VirtAddr = struct {
    l1: u9, // Bits 38:30
    l2: u9, // Bits 29:21
    l3: u9, // Bits 20:12
    offset: u12,

    pub inline fn parse(vaddr: usize) VirtAddr {
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

pub const Tcr = struct {
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
        if (is_aarch64) return asm volatile ("mrs %[ret], tcr_el1"
            : [ret] "=r" (-> u64),
        );
        return 0;
    }

    pub fn write(value: u64) void {
        if (is_aarch64) asm volatile ("msr tcr_el1, %[val]"
            :
            : [val] "r" (value),
        );
    }
};

const Sctlr = struct {
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
    if (is_aarch64) asm volatile ("dsb ishst");
}

inline fn fullBarrier() void {
    if (is_aarch64) asm volatile ("dsb ish");
}

/// Flushes pipeline after MMU configuration changes.
inline fn instructionBarrier() void {
    if (is_aarch64) asm volatile ("isb");
}

inline fn tlbFlushAll() void {
    if (is_aarch64) asm volatile ("tlbi alle1is");
}

inline fn tlbFlushLocal() void {
    if (is_aarch64) asm volatile ("tlbi vmalle1");
}

// TODO(smp): After secondary cores are online, always use broadcast (flushAll).
// During boot, use flushLocal() since secondary cores aren't initialized.
pub const Tlb = struct {
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
        if (is_aarch64) asm volatile ("tlbi vale1is, %[va]"
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
        if (is_aarch64) asm volatile ("tlbi aside1is, %[asid]"
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
        if (is_aarch64) asm volatile ("tlbi vae1is, %[op]"
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
pub fn walk(root: *PageTable, vaddr: usize) ?*Pte {
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

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
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

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
    if (!VirtAddr.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtAddr.parse(vaddr);

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
        l3_entry.* = Pte.userPage(paddr, flags.write, flags.exec);
    } else {
        l3_entry.* = Pte.kernelPage(paddr, flags.write, flags.exec);
    }
    storeBarrier();
}

/// Map a 4KB page, allocating intermediate tables as needed.
/// Allocator must provide zeroed pages (use page_allocator from PMM wrapper).
/// Does NOT flush TLB - caller must do that after mapping.
/// TODO(smp): Caller must hold page table lock.
pub fn mapPageWithAlloc(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags, allocator: std.mem.Allocator) MapError!void {
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtAddr.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtAddr.parse(vaddr);

    // Level 1 - allocate L2 table if needed
    var l1_entry = &root.entries[va.l1];
    if (!l1_entry.isValid()) {
        const l2_phys = allocPageTable(allocator) orelse return MapError.OutOfMemory;
        l1_entry.* = Pte.table(l2_phys);
        storeBarrier();
    } else if (!l1_entry.isTable()) {
        return MapError.SuperpageConflict;
    }

    // Level 2 - allocate L3 table if needed
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    var l2_entry = &l2_table.entries[va.l2];
    if (!l2_entry.isValid()) {
        const l3_phys = allocPageTable(allocator) orelse return MapError.OutOfMemory;
        l2_entry.* = Pte.table(l3_phys);
        storeBarrier();
    } else if (!l2_entry.isTable()) {
        return MapError.SuperpageConflict;
    }

    // Level 3 - the actual page entry
    const l3_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l3_entry = &l3_table.entries[va.l3];
    if (l3_entry.isValid()) return MapError.AlreadyMapped;

    if (flags.user) {
        l3_entry.* = Pte.userPage(paddr, flags.write, flags.exec);
    } else {
        l3_entry.* = Pte.kernelPage(paddr, flags.write, flags.exec);
    }
    storeBarrier();
}

/// Allocate a zeroed page table using std.mem.Allocator.
/// Returns physical address or null on OOM.
fn allocPageTable(allocator: std.mem.Allocator) ?usize {
    const page = allocator.alignedAlloc(u8, PAGE_SIZE, PAGE_SIZE) catch return null;
    @memset(page, 0);
    return virtToPhys(@intFromPtr(page.ptr));
}

/// Unmap a 4KB page at the given virtual address.
/// Returns the physical address that was mapped, or null if not mapped.
/// Does NOT flush TLB - caller must do that after unmapping (allows batching).
/// TODO(smp): Caller must hold page table lock.
pub fn unmapPage(root: *PageTable, vaddr: usize) ?usize {
    const entry = walk(root, vaddr) orelse return null;
    if (!entry.isValid()) return null;

    const paddr = entry.physAddr();
    entry.* = Pte.INVALID;
    storeBarrier();
    return paddr;
}

/// Unmap a 4KB page and immediately flush TLB for that address.
/// Convenience wrapper when batching is not needed.
pub fn unmapPageAndFlush(root: *PageTable, vaddr: usize) ?usize {
    const paddr = unmapPage(root, vaddr) orelse return null;
    Tlb.flushAddr(vaddr);
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

    Tcr.write(Tcr.DEFAULT);
    instructionBarrier();

    // Calculate mapping to cover both kernel and DTB
    const kernel_start = kernel_phys_load;
    const dtb_end = if (dtb_ptr > 0) dtb_ptr + (1 << 20) else kernel_phys_load;
    const map_end = @max(kernel_phys_load + (1 << 30), dtb_end);
    const start_gb = kernel_start >> 30;
    const end_gb = (map_end + (1 << 30) - 1) >> 30;
    physmap_end_gb = end_gb;

    // TTBR0: Identity mapping (for boot continuation after MMU enable)
    l1_table_low.entries[0] = Pte.deviceBlock(0); // MMIO (first GB)

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l1_table_low.entries[gb] = Pte.kernelBlock(gb << 30, true, true);
    }

    // TTBR1: Higher-half kernel mapping
    l1_table_high.entries[0] = Pte.deviceBlock(0); // MMIO in higher-half

    gb = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l1_table_high.entries[gb] = Pte.kernelBlock(gb << 30, true, true);
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
    Tlb.flushLocal();

    Sctlr.enableMmu();
}

/// Expand physmap to cover all RAM. Called after DTB is readable.
/// Uses 1GB blocks - no page allocation needed, just L1 entries.
///
/// BOOT-TIME ONLY: Called from virtInit() on primary core before SMP.
pub fn expandPhysmap(ram_size: usize) void {
    const new_end = stored_kernel_phys_load + ram_size;
    const new_end_gb = @min((new_end + (1 << 30) - 1) >> 30, MAX_PHYSMAP_ENTRIES);

    var gb = physmap_end_gb;
    while (gb < new_end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l1_table_high.entries[gb] = Pte.kernelBlock(gb << 30, true, true);
    }

    if (new_end_gb > physmap_end_gb) {
        Tlb.flushLocal(); // Local only - secondary cores not running yet
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
    Tlb.flushAll();
}

/// Remove identity mapping after transitioning to higher-half.
/// Improves security by preventing kernel access via low addresses.
/// Called from virtInit() on primary core before SMP.
pub fn removeIdentityMapping() void {
    const start_gb = stored_kernel_phys_load >> 30;
    const end_gb = physmap_end_gb;

    l1_table_low.entries[0] = Pte.INVALID; // Clear MMIO identity mapping

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        l1_table_low.entries[gb] = Pte.INVALID;
    }

    Tlb.flushLocal();
}

test "Pte size and layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Pte));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(Pte));
}

test "Pte.INVALID is all zeros" {
    const invalid: u64 = @bitCast(Pte.INVALID);
    try std.testing.expectEqual(@as(u64, 0), invalid);
}

test "Pte.table creates valid table entry" {
    const desc = Pte.table(0x80000000);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.isTable());
    try std.testing.expect(!desc.isBlock());
    try std.testing.expectEqual(@as(usize, 0x80000000), desc.physAddr());
}

test "Pte.kernelBlock creates valid block entry" {
    const desc = Pte.kernelBlock(0x40000000, true, true);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.isBlock());
    try std.testing.expect(!desc.ng);
    try std.testing.expect(desc.af);
}

test "Pte.deviceBlock has correct attributes" {
    const desc = Pte.deviceBlock(0x09000000);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.isBlock());
    try std.testing.expectEqual(@intFromEnum(MemAttr.device_nGnRnE), desc.attr_idx);
    try std.testing.expect(desc.pxn);
    try std.testing.expect(desc.uxn);
}

test "Pte.userPage creates non-global entry" {
    const desc = Pte.userPage(0x1000, true, false);
    try std.testing.expect(desc.isValid());
    try std.testing.expect(desc.ng);
    try std.testing.expect(desc.ap1);
    try std.testing.expect(desc.uxn);
}

test "VirtAddr.parse extracts correct indices" {
    const va = VirtAddr.parse(0x40080000);
    try std.testing.expectEqual(@as(u9, 1), va.l1);
    try std.testing.expectEqual(@as(u9, 0), va.l2);
    try std.testing.expectEqual(@as(u9, 128), va.l3);
    try std.testing.expectEqual(@as(u12, 0), va.offset);
}

test "VirtAddr.isUserRange for TTBR0 (39-bit VA)" {
    try std.testing.expect(VirtAddr.isUserRange(0x0000_0000_0000_0000));
    try std.testing.expect(VirtAddr.isUserRange(0x0000_007F_FFFF_FFFF));
    try std.testing.expect(!VirtAddr.isUserRange(0x0000_0080_0000_0000));
}

test "VirtAddr.isKernel for TTBR1 addresses" {
    try std.testing.expect(VirtAddr.isKernel(0xFFFF_FF80_0000_0000));
    try std.testing.expect(VirtAddr.isKernel(0xFFFF_FFFF_FFFF_FFFF));
    try std.testing.expect(VirtAddr.isKernel(KERNEL_VIRT_BASE));
    try std.testing.expect(!VirtAddr.isKernel(0x0000_0000_0000_0000));
    try std.testing.expect(!VirtAddr.isKernel(0x0000_007F_FFFF_FFFF));
}

test "VirtAddr.isCanonical accepts both ranges" {
    try std.testing.expect(VirtAddr.isCanonical(0x0000_0000_0000_0000));
    try std.testing.expect(VirtAddr.isCanonical(0x0000_007F_FFFF_FFFF));
    try std.testing.expect(VirtAddr.isCanonical(0xFFFF_FF80_0000_0000));
    try std.testing.expect(VirtAddr.isCanonical(0xFFFF_FFFF_FFFF_FFFF));
    try std.testing.expect(!VirtAddr.isCanonical(0x0000_0080_0000_0000));
    try std.testing.expect(!VirtAddr.isCanonical(0x8000_0000_0000_0000));
}

test "PageTable size matches page size" {
    try std.testing.expectEqual(PAGE_SIZE, @sizeOf(PageTable));
}

test "Tcr.DEFAULT produces valid configuration" {
    const tcr = Tcr.DEFAULT;
    try std.testing.expectEqual(@as(u64, 25), tcr & 0x3F);
    try std.testing.expectEqual(@as(u64, 25), (tcr >> 16) & 0x3F);
    try std.testing.expectEqual(@as(u64, 0b10), (tcr >> 12) & 0x3);
}

test "translate handles 1GB block mappings" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true);

    const pa = translate(&root, 0x40123456);
    try std.testing.expectEqual(@as(?usize, 0x40123456), pa);
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x80000000));
}

test "translate returns null for non-canonical addresses" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true);
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x0000_0080_0000_0000));
}

test "mapPage returns NotAligned for misaligned addresses" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1001, 0x2000, .{}));
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1000, 0x2001, .{}));
}

test "mapPage returns NotCanonical for non-canonical addresses" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x0000_0080_0000_0000, 0x1000, .{}));
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x8000_0000_0000_0000, 0x1000, .{}));
}

test "mapPage returns SuperpageConflict for block mappings" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true);
    try std.testing.expectError(MapError.SuperpageConflict, mapPage(&root, 0x40001000, 0x80001000, .{}));
}

test "mapPage returns TableNotPresent without intermediate tables" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.TableNotPresent, mapPage(&root, 0x40001000, 0x80001000, .{}));
}

test "walk returns null for unmapped address" {
    var root = PageTable.EMPTY;
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x40001000));
}

test "walk returns null for block mapping" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true);
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x40001000));
}

test "physToVirt adds KERNEL_VIRT_BASE" {
    const virt = physToVirt(0x40080000);
    try std.testing.expectEqual(@as(usize, 0xFFFF_FF80_4008_0000), virt);
}

test "virtToPhys subtracts KERNEL_VIRT_BASE" {
    const phys = virtToPhys(0xFFFF_FF80_4008_0000);
    try std.testing.expectEqual(@as(usize, 0x40080000), phys);
}

test "physToVirt and virtToPhys are inverses" {
    const original: usize = 0x40080000;
    const round_trip = virtToPhys(physToVirt(original));
    try std.testing.expectEqual(original, round_trip);
}
