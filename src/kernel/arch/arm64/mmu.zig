//! ARM64 MMU - 39-bit virtual address, 4KB granule, 3-level page tables.
//! ARM64 calls these "descriptors"; we use "Pte" to match RISC-V and OS literature.
//! Uses T0SZ=25/T1SZ=25 for 3-level walk (L1 -> L2 -> L3), matching RISC-V Sv39 depth.
//! Boot maps with 1GB blocks at level 1 to avoid allocating level 2/3 tables.
//! TTBR0 handles identity mapping (low addresses), TTBR1 handles higher-half kernel.
//!
//! TODO(Rung 8): Use ASID for per-process TLB management. Currently ASID=0 for all
//! mappings. When implementing per-task virtual memory, assign unique ASIDs to
//! processes and use flushAsid() instead of flushAll() for efficient TLB invalidation.

const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("../../kernel.zig");

const is_aarch64 = builtin.cpu.arch == .aarch64;

// Re-export common types for convenience
pub const PAGE_SIZE = kernel.mmu.PAGE_SIZE;
pub const PAGE_SHIFT = kernel.mmu.PAGE_SHIFT;
pub const ENTRIES_PER_TABLE = kernel.mmu.ENTRIES_PER_TABLE;
pub const PageFlags = kernel.mmu.PageFlags;
pub const MapError = kernel.mmu.MapError;
pub const UnmapError = kernel.mmu.UnmapError;

/// Kernel virtual base address (39-bit VA upper half, TTBR1 region).
/// Physical addresses are mapped to virtual = physical + KERNEL_VIRT_BASE.
/// With T1SZ=25 (39-bit VA), TTBR1 handles addresses where bits 63:39 are all 1s.
/// This means the valid TTBR1 range starts at 0xFFFF_FF80_0000_0000.
pub const KERNEL_VIRT_BASE: usize = 0xFFFF_FF80_0000_0000;

// Offset masks for block translation
const BLOCK_1GB_MASK: usize = (1 << 30) - 1; // 1GB offset mask
const BLOCK_2MB_MASK: usize = (1 << 21) - 1; // 2MB offset mask

/// Convert physical address to kernel virtual address.
pub fn physToVirt(paddr: usize) usize {
    return paddr +% KERNEL_VIRT_BASE;
}

/// Convert kernel virtual address to physical address.
pub fn virtToPhys(vaddr: usize) usize {
    return vaddr -% KERNEL_VIRT_BASE;
}

// Memory attribute indices for MAIR_EL1
pub const MemAttr = enum(u3) {
    device_nGnRnE = 0,
    device_nGnRE = 1,
    normal_nc = 2,
    normal_wbwa = 3,
    normal_tagged = 4,
};

const MAIR_VALUE: u64 =
    (@as(u64, 0x00) << 0) | // Device nGnRnE
    (@as(u64, 0x04) << 8) | // Device nGnRE
    (@as(u64, 0x44) << 16) | // Normal NC
    (@as(u64, 0xFF) << 24) | // Normal WBWA
    (@as(u64, 0xF0) << 32); // Normal Tagged

// Shareability domain for cache coherency.
// Inner shareable = coherent within cluster (typical for multicore).
// Device memory uses outer shareable per ARM recommendations.
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
    ap1: bool = false, // user access
    ap2: bool = false, // read-only
    sh: Shareability = .non_shareable,
    af: bool = false, // access flag
    ng: bool = false, // non-global (per-ASID)
    output_addr: u36 = 0,
    reserved1: u4 = 0,
    cont: bool = false,
    pxn: bool = false, // privileged execute never
    uxn: bool = false, // user execute never
    sw_bits: u4 = 0,
    reserved2: u5 = 0,

    pub const INVALID = Pte{};

    pub fn isValid(self: Pte) bool {
        return self.valid;
    }

    pub fn isTable(self: Pte) bool {
        return self.valid and self.type_bit;
    }

    pub fn isBlock(self: Pte) bool {
        return self.valid and !self.type_bit;
    }

    pub fn physAddr(self: Pte) usize {
        return @as(usize, self.output_addr) << PAGE_SHIFT;
    }

    pub fn table(next_table_phys: usize) Pte {
        return .{ .valid = true, .type_bit = true, .output_addr = @truncate(next_table_phys >> PAGE_SHIFT) };
    }

    /// Create kernel block entry (1GB or 2MB). All valid mappings are implicitly readable.
    /// ARM64 AP bits only distinguish RW vs RO - no write-only pages possible.
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

    /// Create user page entry (4KB). All valid mappings are implicitly readable.
    /// Sets non-global bit for per-ASID TLB invalidation.
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

pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]Pte,

    pub const EMPTY = PageTable{ .entries = [_]Pte{Pte.INVALID} ** ENTRIES_PER_TABLE };

    pub fn get(self: *const PageTable, index: usize) Pte {
        return self.entries[index];
    }

    pub fn set(self: *PageTable, index: usize, desc: Pte) void {
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
    l1: u9, // bits 38:30
    l2: u9, // bits 29:21
    l3: u9, // bits 20:12
    offset: u12,

    pub fn parse(vaddr: usize) VirtAddr {
        return .{
            .l1 = @truncate((vaddr >> 30) & 0x1FF),
            .l2 = @truncate((vaddr >> 21) & 0x1FF),
            .l3 = @truncate((vaddr >> 12) & 0x1FF),
            .offset = @truncate(vaddr & 0xFFF),
        };
    }

    /// Check if address is in TTBR0 range (user space, low addresses 0 to 512GB).
    pub fn isUserRange(vaddr: usize) bool {
        return vaddr < (1 << 39);
    }

    /// Check if address is valid for TTBR1 (kernel space, high addresses).
    /// With T1SZ=25, TTBR1 handles addresses where bits 63:39 are all 1s.
    pub fn isKernel(vaddr: usize) bool {
        return (vaddr & KERNEL_VIRT_BASE) == KERNEL_VIRT_BASE;
    }

    /// Check if address is in valid range (either TTBR0 or TTBR1).
    pub fn isCanonical(vaddr: usize) bool {
        return isUserRange(vaddr) or isKernel(vaddr);
    }
};

pub const Tcr = struct {
    /// TCR_EL1: T0SZ=25 (39-bit VA), 4KB granule, both TTBR0 and TTBR1 enabled
    /// TTBR0 for lower addresses (identity mapping during boot)
    /// TTBR1 for upper addresses (kernel higher-half)
    pub fn build() u64 {
        var tcr: u64 = 0;
        tcr |= 25; // T0SZ - 39-bit VA for TTBR0
        tcr |= (0b01 << 8); // IRGN0 write-back
        tcr |= (0b01 << 10); // ORGN0 write-back
        tcr |= (0b10 << 12); // SH0 inner shareable
        tcr |= (0b00 << 14); // TG0 4KB granule (explicit, 0b00 = 4KB)
        tcr |= (25 << 16); // T1SZ - 39-bit VA for TTBR1
        // EPD1 = 0 (bit 23 not set) - TTBR1 enabled for higher-half kernel
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

// Memory barriers (ARM requires explicit ordering for page table updates).
// Data barrier ensures stores complete before TLB invalidation.
// Instruction barrier flushes pipeline after MMU configuration changes.
inline fn storeBarrier() void {
    if (is_aarch64) asm volatile ("dsb ishst");
}
inline fn fullBarrier() void {
    if (is_aarch64) asm volatile ("dsb ish");
}
inline fn instructionBarrier() void {
    if (is_aarch64) asm volatile ("isb");
}

inline fn tlbFlushAll() void {
    if (is_aarch64) asm volatile ("tlbi alle1is");
}

inline fn tlbFlushLocal() void {
    if (is_aarch64) asm volatile ("tlbi vmalle1");
}

pub const Tlb = struct {
    /// Invalidate all translation lookaside buffer entries (broadcast to inner shareable domain).
    pub fn flushAll() void {
        storeBarrier();
        tlbFlushAll();
        fullBarrier();
        instructionBarrier();
    }

    /// Invalidate cached translation for a specific virtual address.
    pub fn flushAddr(vaddr: usize) void {
        const va_operand = (vaddr >> 12) & 0xFFFFFFFFFFF;
        storeBarrier();
        if (is_aarch64) asm volatile ("tlbi vale1is, %[va]"
            :
            : [va] "r" (va_operand),
        );
        fullBarrier();
        instructionBarrier();
    }

    /// Invalidate all cached translations for a specific address space.
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
        // VAE1IS operand: bits 63:48 = ASID, bits 43:0 = VA[55:12]
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

/// Walk page tables for a virtual address and return pointer to the leaf entry.
/// Returns null if any level has an invalid entry or if a block mapping is found
/// before reaching level 3 (can't get individual page entry from block).
/// Note: This walks to the L3 (4KB page) level only.
/// Page tables are accessed via higher-half virtual addresses after MMU enable.
pub fn walk(root: *PageTable, vaddr: usize) ?*Pte {
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

    // Level 1
    const l1_entry = &root.entries[va.l1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isBlock()) return null; // 1GB block, not page-level

    // Level 2 - convert physical address to virtual for access
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l2_entry = &l2_table.entries[va.l2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isBlock()) return null; // 2MB block, not page-level

    // Level 3 - convert physical address to virtual for access
    const l3_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    return &l3_table.entries[va.l3];
}

/// Translate virtual address to physical address.
/// Handles block mappings at any level as well as page mappings.
/// Returns null if address is not mapped.
/// Page tables are accessed via higher-half virtual addresses after MMU enable.
pub fn translate(root: *PageTable, vaddr: usize) ?usize {
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

    // Level 1
    const l1_entry = root.entries[va.l1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isBlock()) {
        // 1GB block: PA = block base + offset within 1GB
        return l1_entry.physAddr() | (vaddr & BLOCK_1GB_MASK);
    }

    // Level 2 - convert physical address to virtual for access
    const l2_table: *const PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l2_entry = l2_table.entries[va.l2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isBlock()) {
        // 2MB block: PA = block base + offset within 2MB
        return l2_entry.physAddr() | (vaddr & BLOCK_2MB_MASK);
    }

    // Level 3 - convert physical address to virtual for access
    const l3_table: *const PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l3_entry = l3_table.entries[va.l3];
    if (!l3_entry.isValid()) return null;

    // 4KB page: PA = page base + offset within page
    return l3_entry.physAddr() | @as(usize, va.offset);
}

/// Map a 4KB page at the given virtual address.
/// Requires all intermediate page tables (L1, L2) to already exist.
/// Does NOT flush TLB - caller must do that after mapping.
/// Page tables are accessed via higher-half virtual addresses after MMU enable.
pub fn mapPage(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags) MapError!void {
    // Check alignment and canonical
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtAddr.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtAddr.parse(vaddr);

    // Level 1 - must be a table entry
    const l1_entry = root.entries[va.l1];
    if (!l1_entry.isValid()) return MapError.TableNotPresent;
    if (!l1_entry.isTable()) return MapError.SuperpageConflict; // 1GB block

    // Level 2 - must be a table entry (convert phys to virt for access)
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l2_entry = l2_table.entries[va.l2];
    if (!l2_entry.isValid()) return MapError.TableNotPresent;
    if (!l2_entry.isTable()) return MapError.SuperpageConflict; // 2MB block

    // Level 3 - the actual page entry (convert phys to virt for access)
    const l3_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l3_entry = &l3_table.entries[va.l3];
    if (l3_entry.isValid()) return MapError.AlreadyMapped;

    // Create the page entry with store barrier to ensure visibility.
    // On multicore systems, another core's MMU could observe the PTE via cache
    // coherency before our store completes. DSB ISHST ensures the store is
    // visible to inner shareable domain before we return to caller.
    if (flags.user) {
        l3_entry.* = Pte.userPage(paddr, flags.write, flags.exec);
    } else {
        l3_entry.* = Pte.kernelPage(paddr, flags.write, flags.exec);
    }
    storeBarrier();
}

/// Unmap a 4KB page at the given virtual address.
/// Returns the physical address that was mapped, or null if not mapped.
/// Does NOT flush TLB - caller must do that after unmapping (allows batching).
pub fn unmapPage(root: *PageTable, vaddr: usize) ?usize {
    const entry = walk(root, vaddr) orelse return null;
    if (!entry.isValid()) return null;

    const paddr = entry.physAddr();
    entry.* = Pte.INVALID;
    // Ensure invalidation is visible before caller flushes TLB.
    // Without this barrier, TLB flush could complete before the PTE write
    // propagates, leaving a window where stale translations are possible.
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

// Boot page tables using 1GB blocks
// TTBR0: identity mapping for boot (low addresses)
// TTBR1: higher-half kernel (high addresses starting at KERNEL_VIRT_BASE)
var l1_table_low: PageTable align(PAGE_SIZE) = PageTable.EMPTY;
var l1_table_high: PageTable align(PAGE_SIZE) = PageTable.EMPTY;

// Kernel size estimate for gigapage mapping (1GB should cover typical kernel)
const KERNEL_SIZE_ESTIMATE: usize = 1 << 30; // 1GB

// Stored during init() for use by removeIdentityMapping()
var stored_kernel_phys_load: usize = 0;

/// Set up identity + higher-half mappings using 1GB blocks, enable MMU.
/// TTBR0 handles identity mapping for boot continuation.
/// TTBR1 handles higher-half kernel addresses (0xFFFF_0000_xxxx_xxxx).
/// kernel_phys_load: Physical address where kernel is loaded (from board config).
pub fn init(kernel_phys_load: usize) void {
    stored_kernel_phys_load = kernel_phys_load;

    asm volatile ("msr mair_el1, %[mair]"
        :
        : [mair] "r" (MAIR_VALUE),
    );
    instructionBarrier();

    Tcr.write(Tcr.DEFAULT);
    instructionBarrier();

    const kernel_start = kernel_phys_load;
    // Estimate kernel end for gigapage mapping (actual end determined at runtime)
    const kernel_end = kernel_phys_load + KERNEL_SIZE_ESTIMATE;
    const start_gb = kernel_start >> 30;
    const end_gb = (kernel_end + (1 << 30) - 1) >> 30;

    // TTBR0: Identity mapping (for boot continuation after MMU enable)
    // MMIO first - ensures it's not overwritten if kernel happens to start in first GB
    // (e.g., on boards where KERNEL_PHYS_LOAD < 0x40000000)
    l1_table_low.entries[0] = Pte.deviceBlock(0); // MMIO (first GB, non-executable)

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        // Skip index 0 if kernel overlaps MMIO region - MMIO takes precedence
        if (gb == 0) continue;
        l1_table_low.entries[gb] = Pte.kernelBlock(gb << 30, true, true);
    }

    // TTBR1: Higher-half kernel mapping
    // ARM64 TTBR1 handles addresses where bits 63:39 are all 1s.
    // For 39-bit VA with T1SZ=25: addresses 0xFFFF_FF80_0000_0000 to 0xFFFF_FFFF_FFFF_FFFF
    // KERNEL_VIRT_BASE = 0xFFFF_FF80_0000_0000 is the start of the TTBR1 region.
    // L1 index = (VA >> 30) & 0x1FF, so physical GB N maps to same L1 index
    l1_table_high.entries[0] = Pte.deviceBlock(0); // MMIO in higher-half

    gb = start_gb;
    while (gb < end_gb) : (gb += 1) {
        // Skip index 0 - already set for MMIO above
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

    // Use local TLBI (vmalle1) not broadcast (alle1is) before MMU enable.
    // Broadcast can fault on some implementations when MMU is off.
    storeBarrier();
    tlbFlushLocal();
    fullBarrier();
    instructionBarrier();

    Sctlr.enableMmu();
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
/// This clears the TTBR0 page table entries that were used during boot.
/// Only call this after successfully running in higher-half.
/// Improves security by preventing kernel access via low addresses.
pub fn removeIdentityMapping() void {
    // Use same range as init() for consistency
    const kernel_start = stored_kernel_phys_load;
    const kernel_end = stored_kernel_phys_load + KERNEL_SIZE_ESTIMATE;
    const start_gb = kernel_start >> 30;
    const end_gb = (kernel_end + (1 << 30) - 1) >> 30;

    // Clear MMIO identity mapping
    l1_table_low.entries[0] = Pte.INVALID;

    // Clear kernel identity mappings
    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        l1_table_low.entries[gb] = Pte.INVALID;
    }

    // Ensure page table writes complete before TLB invalidation
    storeBarrier();
    tlbFlushLocal();
    fullBarrier();
    instructionBarrier();
}

/// Transition to running in higher-half address space.
/// Jumps to the higher-half address of the continuation function and
/// updates the stack pointer to its higher-half equivalent.
/// The continuation function receives the same argument passed here.
/// Must be called after init() has set up higher-half mappings.
pub fn jumpToHigherHalf(continuation: *const fn (usize) noreturn, arg: usize) noreturn {
    // Compute higher-half addresses
    const high_continuation = @intFromPtr(continuation) +% KERNEL_VIRT_BASE;
    const current_sp = asm volatile ("mov %[sp], sp"
        : [sp] "=r" (-> usize),
    );
    const high_sp = current_sp +% KERNEL_VIRT_BASE;

    // Jump to higher-half with new stack pointer.
    // No clobbers needed since this function never returns.
    asm volatile (
        \\ mov sp, %[new_sp]
        \\ br %[target]
        :
        : [new_sp] "r" (high_sp),
          [target] "r" (high_continuation),
          [arg] "{x0}" (arg),
    );
    unreachable;
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
    // Valid TTBR1 addresses (bits 63:39 all 1s)
    try std.testing.expect(VirtAddr.isKernel(0xFFFF_FF80_0000_0000));
    try std.testing.expect(VirtAddr.isKernel(0xFFFF_FFFF_FFFF_FFFF));
    try std.testing.expect(VirtAddr.isKernel(KERNEL_VIRT_BASE));
    // Invalid - not all high bits set
    try std.testing.expect(!VirtAddr.isKernel(0x0000_0000_0000_0000));
    try std.testing.expect(!VirtAddr.isKernel(0x0000_007F_FFFF_FFFF));
}

test "VirtAddr.isCanonical accepts both ranges" {
    // TTBR0 range
    try std.testing.expect(VirtAddr.isCanonical(0x0000_0000_0000_0000));
    try std.testing.expect(VirtAddr.isCanonical(0x0000_007F_FFFF_FFFF));
    // TTBR1 range
    try std.testing.expect(VirtAddr.isCanonical(0xFFFF_FF80_0000_0000));
    try std.testing.expect(VirtAddr.isCanonical(0xFFFF_FFFF_FFFF_FFFF));
    // Invalid - hole between TTBR0 and TTBR1
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
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true); // 1GB at index 1

    // Address in middle of block should translate correctly
    const pa = translate(&root, 0x40123456);
    try std.testing.expectEqual(@as(?usize, 0x40123456), pa);

    // Unmapped address returns null
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x80000000));
}

test "translate returns null for non-canonical addresses" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true);

    // Non-canonical address in the hole
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x0000_0080_0000_0000));
}

test "mapPage returns NotAligned for misaligned addresses" {
    var root = PageTable.EMPTY;

    // Misaligned virtual address
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1001, 0x2000, .{}));

    // Misaligned physical address
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1000, 0x2001, .{}));
}

test "mapPage returns NotCanonical for non-canonical addresses" {
    var root = PageTable.EMPTY;

    // Address in the hole between TTBR0 and TTBR1
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x0000_0080_0000_0000, 0x1000, .{}));
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x8000_0000_0000_0000, 0x1000, .{}));
}

test "mapPage returns SuperpageConflict for block mappings" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true); // 1GB block

    // Trying to map a page inside a block should fail
    try std.testing.expectError(MapError.SuperpageConflict, mapPage(&root, 0x40001000, 0x80001000, .{}));
}

test "mapPage returns TableNotPresent without intermediate tables" {
    var root = PageTable.EMPTY;

    // No L1 entry present
    try std.testing.expectError(MapError.TableNotPresent, mapPage(&root, 0x40001000, 0x80001000, .{}));
}

test "walk returns null for unmapped address" {
    var root = PageTable.EMPTY;
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x40001000));
}

test "walk returns null for block mapping" {
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelBlock(0x40000000, true, true);

    // Block mapping - can't walk to page level
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x40001000));
}

test "physToVirt adds KERNEL_VIRT_BASE" {
    // Physical 0x40080000 should map to virtual 0xFFFF_FF80_4008_0000
    const virt = physToVirt(0x40080000);
    try std.testing.expectEqual(@as(usize, 0xFFFF_FF80_4008_0000), virt);
}

test "virtToPhys subtracts KERNEL_VIRT_BASE" {
    // Virtual 0xFFFF_FF80_4008_0000 should map to physical 0x40080000
    const phys = virtToPhys(0xFFFF_FF80_4008_0000);
    try std.testing.expectEqual(@as(usize, 0x40080000), phys);
}

test "physToVirt and virtToPhys are inverses" {
    const original: usize = 0x40080000;
    const round_trip = virtToPhys(physToVirt(original));
    try std.testing.expectEqual(original, round_trip);
}
