//! RISC-V Sv39 MMU - 39-bit virtual address, 3-level page tables.
//! Virtual address format: VPN[2](9b) | VPN[1](9b) | VPN[0](9b) | offset(12b)
//! Boot uses 1GB gigapages (leaf entries at level 2) to avoid allocating lower tables.
//! Gigapage requires physical address to be 1GB-aligned.
//!
//! TODO(Rung 8): Use ASID for per-process TLB management. Currently ASID=0 for all
//! mappings. When implementing per-task virtual memory, assign unique ASIDs to
//! processes and use flushAsid() instead of flushAll() for efficient TLB invalidation.

const std = @import("std");
const builtin = @import("builtin");
const common_mmu = @import("common").mmu;

const is_riscv64 = builtin.cpu.arch == .riscv64;

// Re-export common types for convenience
pub const PAGE_SIZE = common_mmu.PAGE_SIZE;
pub const PAGE_SHIFT = common_mmu.PAGE_SHIFT;
pub const ENTRIES_PER_TABLE = common_mmu.ENTRIES_PER_TABLE;
pub const PageFlags = common_mmu.PageFlags;
pub const MapError = common_mmu.MapError;

/// Kernel virtual base address (Sv39 upper canonical).
/// Physical addresses are mapped to virtual = physical + KERNEL_VIRT_BASE.
/// This places kernel in the upper half of the 39-bit address space.
pub const KERNEL_VIRT_BASE: usize = 0xFFFF_FFC0_0000_0000;

/// Convert physical address to kernel virtual address.
pub fn physToVirt(paddr: usize) usize {
    return paddr +% KERNEL_VIRT_BASE;
}

/// Convert kernel virtual address to physical address.
pub fn virtToPhys(vaddr: usize) usize {
    return vaddr -% KERNEL_VIRT_BASE;
}

/// Sv39 Page Table Entry (8 bytes).
/// Leaf vs branch: if any of read/write/execute set, it's a leaf (final translation).
/// If valid=1 and read=write=execute=0, it's a branch (pointer to next level).
pub const Pte = packed struct(u64) {
    v: bool = false, // valid
    r: bool = false, // read permission
    w: bool = false, // write permission
    x: bool = false, // execute permission
    u: bool = false, // user accessible
    g: bool = false, // global (entry persists across address space switch)
    a: bool = false, // accessed (set by hardware or software)
    d: bool = false, // dirty (set by hardware or software on write)
    rsw: u2 = 0, // reserved for software
    ppn: u44 = 0, // physical page number
    reserved: u10 = 0, // must be zero for Sv39

    pub const EMPTY = Pte{};

    /// Check if this entry is valid (present in page table).
    pub fn isValid(self: Pte) bool {
        return self.v;
    }

    /// Check if this is a leaf entry (final translation with permissions).
    pub fn isLeaf(self: Pte) bool {
        return self.r or self.w or self.x;
    }

    /// Check if this is a branch entry (pointer to next level table).
    pub fn isBranch(self: Pte) bool {
        return self.v and !self.isLeaf();
    }

    /// Extract the physical address from this entry.
    pub fn physAddr(self: Pte) usize {
        return @as(usize, self.ppn) << PAGE_SHIFT;
    }

    /// Create a branch entry pointing to the next level page table.
    pub fn branch(phys_addr: usize) Pte {
        return .{ .v = true, .ppn = @truncate(phys_addr >> PAGE_SHIFT) };
    }

    /// Kernel leaf entry. Pre-sets accessed/dirty to avoid page faults on first access
    /// (Svadu extension would set these in hardware, but we don't rely on it).
    /// All valid mappings are implicitly readable - RISC-V spec requires R=1 when W=1.
    pub fn kernelLeaf(phys_addr: usize, write: bool, exec: bool) Pte {
        return .{
            .v = true,
            .r = true, // Always readable; W=1,R=0 is reserved in RISC-V
            .w = write,
            .x = exec,
            .g = true, // global - not flushed on address space change
            .a = true, // pre-set to avoid access fault
            .d = write, // pre-set if writable to avoid store fault
            .ppn = @truncate(phys_addr >> PAGE_SHIFT),
        };
    }

    /// User leaf entry. Sets user-accessible bit and pre-sets accessed/dirty.
    /// All valid mappings are implicitly readable - RISC-V spec requires R=1 when W=1.
    pub fn userLeaf(phys_addr: usize, write: bool, exec: bool) Pte {
        return .{
            .v = true,
            .r = true, // Always readable; W=1,R=0 is reserved in RISC-V
            .w = write,
            .x = exec,
            .u = true,
            .a = true,
            .d = write,
            .ppn = @truncate(phys_addr >> PAGE_SHIFT),
        };
    }
};

comptime {
    if (@sizeOf(Pte) != 8) @compileError("PTE must be 8 bytes");
}

/// Page table containing 512 entries (one 4KB page).
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]Pte,

    pub const EMPTY = PageTable{ .entries = [_]Pte{Pte.EMPTY} ** ENTRIES_PER_TABLE };

    /// Read entry at given index.
    pub fn get(self: *const PageTable, index: usize) Pte {
        return self.entries[index];
    }

    /// Write entry at given index.
    pub fn set(self: *PageTable, index: usize, pte: Pte) void {
        self.entries[index] = pte;
    }
};

comptime {
    if (@sizeOf(PageTable) != PAGE_SIZE) @compileError("PageTable must be one page");
}


/// Sv39 virtual address parsing into page table indices.
pub const VirtAddr = struct {
    vpn2: u9, // bits 38:30 (level 2, top level)
    vpn1: u9, // bits 29:21 (level 1)
    vpn0: u9, // bits 20:12 (level 0, leaf)
    offset: u12,

    /// Parse a virtual address into its component indices.
    pub fn parse(vaddr: usize) VirtAddr {
        return .{
            .vpn2 = @truncate((vaddr >> 30) & 0x1FF),
            .vpn1 = @truncate((vaddr >> 21) & 0x1FF),
            .vpn0 = @truncate((vaddr >> 12) & 0x1FF),
            .offset = @truncate(vaddr & 0xFFF),
        };
    }

    /// Check if address is canonical (bits 63:39 are sign-extension of bit 38).
    pub fn isCanonical(vaddr: usize) bool {
        const high_bits = vaddr >> 38;
        return high_bits == 0 or high_bits == 0x3FFFFFF;
    }
};

/// SATP register (mode + address space ID + root physical page number).
pub const Satp = packed struct(u64) {
    ppn: u44, // physical page number of root table
    asid: u16, // address space identifier
    mode: u4, // translation mode (0=bare, 8=Sv39)

    pub const MODE_BARE: u4 = 0;
    pub const MODE_SV39: u4 = 8;

    /// Create SATP value for Sv39 mode with given root table and address space ID.
    pub fn sv39(root_phys: usize, asid: u16) Satp {
        return .{ .ppn = @truncate(root_phys >> PAGE_SHIFT), .asid = asid, .mode = MODE_SV39 };
    }

    /// Create SATP value for bare mode (MMU disabled).
    pub fn bare() Satp {
        return .{ .ppn = 0, .asid = 0, .mode = MODE_BARE };
    }

    /// Read current SATP register value.
    pub fn read() Satp {
        if (is_riscv64) {
            return @bitCast(asm volatile ("csrr %[ret], satp"
                : [ret] "=r" (-> u64),
            ));
        }
        return .{};
    }

    /// Write SATP register to change address translation mode.
    pub fn write(self: Satp) void {
        if (is_riscv64) asm volatile ("csrw satp, %[val]" :: [val] "r" (@as(u64, @bitCast(self))));
    }
};

comptime {
    if (@sizeOf(Satp) != 8) @compileError("SATP must be 8 bytes");
}

// Memory barrier for RISC-V.
// fence rw, rw ensures all prior reads/writes complete before subsequent ones.
// Required after SATP writes to ensure new translations take effect.
inline fn fence() void {
    if (is_riscv64) asm volatile ("fence rw, rw");
}

/// TLB (translation lookaside buffer) management.
/// SFENCE.VMA synchronizes page table updates with address translation hardware.
/// More specific flushes (by address or address space) reduce cache invalidation overhead.
pub const Tlb = struct {
    /// Invalidate all cached address translations.
    pub fn flushAll() void {
        if (is_riscv64) asm volatile ("sfence.vma zero, zero");
    }

    /// Invalidate cached translation for a specific virtual address.
    pub fn flushAddr(vaddr: usize) void {
        if (is_riscv64) asm volatile ("sfence.vma %[addr], zero" :: [addr] "r" (vaddr));
    }

    /// Invalidate all cached translations for a specific address space.
    pub fn flushAsid(asid: u16) void {
        if (is_riscv64) asm volatile ("sfence.vma zero, %[asid]" :: [asid] "r" (@as(usize, asid)));
    }

    /// Invalidate cached translation for a specific virtual address and address space.
    pub fn flushAddrAsid(vaddr: usize, asid: u16) void {
        if (is_riscv64) asm volatile ("sfence.vma %[addr], %[asid]" :: [addr] "r" (vaddr), [asid] "r" (@as(usize, asid)));
    }
};

/// Walk page tables for a virtual address and return pointer to the leaf entry.
/// Returns null if any level has an invalid entry or if a superpage is found
/// before reaching level 0 (can't get individual page entry from superpage).
/// Note: This walks to level 0 (4KB page) only.
/// Page tables are accessed via higher-half virtual addresses after MMU enable.
pub fn walk(root: *PageTable, vaddr: usize) ?*Pte {
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

    // Level 2 (root)
    const l2_entry = &root.entries[va.vpn2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isLeaf()) return null; // gigapage, not page-level

    // Level 1 - convert physical address to virtual for access
    const l1_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l1_entry = &l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isLeaf()) return null; // megapage, not page-level

    // Level 0 - convert physical address to virtual for access
    const l0_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    return &l0_table.entries[va.vpn0];
}

/// Translate virtual address to physical address.
/// Handles superpages at any level as well as regular pages.
/// Returns null if address is not mapped.
/// Page tables are accessed via higher-half virtual addresses after MMU enable.
pub fn translate(root: *PageTable, vaddr: usize) ?usize {
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

    // Level 2 (root)
    const l2_entry = root.entries[va.vpn2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isLeaf()) {
        // 1GB gigapage: PA = page base + offset within 1GB
        return l2_entry.physAddr() | (vaddr & ((1 << 30) - 1));
    }

    // Level 1 - convert physical address to virtual for access
    const l1_table: *const PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l1_entry = l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isLeaf()) {
        // 2MB megapage: PA = page base + offset within 2MB
        return l1_entry.physAddr() | (vaddr & ((1 << 21) - 1));
    }

    // Level 0 - convert physical address to virtual for access
    const l0_table: *const PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l0_entry = l0_table.entries[va.vpn0];
    if (!l0_entry.isValid()) return null;

    // 4KB page: PA = page base + offset within page
    return l0_entry.physAddr() | @as(usize, va.offset);
}

/// Map a 4KB page at the given virtual address.
/// Requires all intermediate page tables (level 2, level 1) to already exist.
/// Does NOT flush TLB - caller must do that after mapping.
/// Page tables are accessed via higher-half virtual addresses after MMU enable.
pub fn mapPage(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags) MapError!void {
    // Check alignment
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtAddr.isCanonical(vaddr)) return MapError.NotAligned;

    const va = VirtAddr.parse(vaddr);

    // Level 2 - must be a branch entry
    const l2_entry = root.entries[va.vpn2];
    if (!l2_entry.isValid()) return MapError.TableNotPresent;
    if (l2_entry.isLeaf()) return MapError.TableNotPresent; // gigapage, not branch

    // Level 1 - must be a branch entry (convert phys to virt for access)
    const l1_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l1_entry = l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) return MapError.TableNotPresent;
    if (l1_entry.isLeaf()) return MapError.TableNotPresent; // megapage, not branch

    // Level 0 - the actual page entry (convert phys to virt for access)
    const l0_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l0_entry = &l0_table.entries[va.vpn0];
    if (l0_entry.isValid()) return MapError.AlreadyMapped;

    // Create the page entry with fence to ensure visibility.
    // RISC-V memory model requires fence before sfence.vma to ensure PTE
    // writes are visible to subsequent page table walks.
    if (flags.user) {
        l0_entry.* = Pte.userLeaf(paddr, flags.write, flags.exec);
    } else {
        l0_entry.* = Pte.kernelLeaf(paddr, flags.write, flags.exec);
    }
    fence();
}

/// Unmap a 4KB page at the given virtual address.
/// Returns the physical address that was mapped, or null if not mapped.
/// Does NOT flush TLB - caller must do that after unmapping (allows batching).
pub fn unmapPage(root: *PageTable, vaddr: usize) ?usize {
    const entry = walk(root, vaddr) orelse return null;
    if (!entry.isValid()) return null;

    const paddr = entry.physAddr();
    entry.* = Pte.EMPTY;
    // Ensure invalidation is visible before caller flushes TLB.
    // Without this fence, sfence.vma could execute before the PTE write
    // propagates, leaving a window where stale translations are possible.
    fence();
    return paddr;
}

/// Unmap a 4KB page and immediately flush TLB for that address.
/// Convenience wrapper when batching is not needed.
pub fn unmapPageAndFlush(root: *PageTable, vaddr: usize) ?usize {
    const paddr = unmapPage(root, vaddr) orelse return null;
    Tlb.flushAddr(vaddr);
    return paddr;
}

// Boot page table (single level-2 table using gigapages)
var root_table: PageTable align(PAGE_SIZE) = PageTable.EMPTY;

// Board-specific memory layout (imported directly to avoid circular deps)
const config = @import("config");
const KERNEL_PHYS_BASE = config.KERNEL_PHYS_BASE;

// Kernel size estimate for gigapage mapping (1GB should cover typical kernel)
const KERNEL_SIZE_ESTIMATE: usize = 1 << 30; // 1GB

/// Set up identity + higher-half mappings using 1GB gigapages, enable Sv39.
/// Identity mapping allows boot code to continue running after MMU enable.
/// Higher-half mapping prepares for eventual transition to high addresses.
pub fn init() void {
    const kernel_start = KERNEL_PHYS_BASE;
    // Estimate kernel end for gigapage mapping (actual end determined at runtime)
    const kernel_end = KERNEL_PHYS_BASE + KERNEL_SIZE_ESTIMATE;
    const start_gb = kernel_start >> 30;
    const end_gb = (kernel_end + (1 << 30) - 1) >> 30;

    // Identity mapping (for boot continuation after MMU enable)
    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        root_table.entries[gb] = Pte.kernelLeaf(gb << 30, true, true);
    }
    root_table.entries[0] = Pte.kernelLeaf(0, true, false); // MMIO

    // Higher-half mapping: physical GB N maps to VPN2 index (high_base + N)
    // For KERNEL_VIRT_BASE = 0xFFFF_FFC0_0000_0000:
    //   VPN2 base = (0xFFFF_FFC0_0000_0000 >> 30) & 0x1FF = 256
    // Physical 0x8000_0000 (GB 2) maps to VPN2 index 258
    const high_base_vpn2: usize = (KERNEL_VIRT_BASE >> 30) & 0x1FF;

    gb = start_gb;
    while (gb < end_gb) : (gb += 1) {
        const high_vpn2 = high_base_vpn2 + gb;
        root_table.entries[high_vpn2] = Pte.kernelLeaf(gb << 30, true, true);
    }
    // MMIO in higher-half
    root_table.entries[high_base_vpn2] = Pte.kernelLeaf(0, true, false);

    // Fence before SATP write ensures all PTE stores are globally visible.
    // Then sfence.vma after SATP change synchronizes address translation.
    fence();
    Satp.sv39(@intFromPtr(&root_table), 0).write();
    Tlb.flushAll();
}

/// Disable MMU. Only safe if running from identity-mapped region.
pub fn disable() void {
    fence();
    Satp.bare().write();
    Tlb.flushAll();
}

/// Remove identity mapping after transitioning to higher-half.
/// This clears the low address mappings (VPN2 indices 0-255) that were used
/// during boot. Only call this after successfully running in higher-half.
/// Improves security by preventing kernel access via low addresses.
pub fn removeIdentityMapping() void {
    // Use same range as init() for consistency
    const kernel_start = KERNEL_PHYS_BASE;
    const kernel_end = KERNEL_PHYS_BASE + KERNEL_SIZE_ESTIMATE;
    const start_gb = kernel_start >> 30;
    const end_gb = (kernel_end + (1 << 30) - 1) >> 30;

    // Clear MMIO identity mapping
    root_table.entries[0] = Pte.EMPTY;

    // Clear kernel identity mappings
    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        root_table.entries[gb] = Pte.EMPTY;
    }

    // Fence before sfence.vma ensures PTE invalidations are visible
    fence();
    Tlb.flushAll();
}

/// Transition to running in higher-half address space.
/// Jumps to the higher-half address of the continuation function and
/// updates the stack pointer to its higher-half equivalent.
/// The continuation function receives the same argument passed here.
/// Must be called after init() has set up higher-half mappings.
pub fn jumpToHigherHalf(continuation: *const fn (usize) noreturn, arg: usize) noreturn {
    // Compute higher-half addresses
    const high_continuation = @intFromPtr(continuation) +% KERNEL_VIRT_BASE;
    const current_sp = asm volatile ("mv %[sp], sp"
        : [sp] "=r" (-> usize),
    );
    const high_sp = current_sp +% KERNEL_VIRT_BASE;

    // Jump to higher-half with new stack pointer.
    // No clobbers needed since this function never returns.
    asm volatile (
        \\ mv sp, %[new_sp]
        \\ jr %[target]
        :
        : [new_sp] "r" (high_sp),
          [target] "r" (high_continuation),
          [arg] "{a0}" (arg),
    );
    unreachable;
}

test "Pte size and layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Pte));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(Pte));
}

test "Pte.EMPTY is all zeros" {
    const empty: u64 = @bitCast(Pte.EMPTY);
    try std.testing.expectEqual(@as(u64, 0), empty);
}

test "Pte.branch creates valid branch entry" {
    const pte = Pte.branch(0x80000000);
    try std.testing.expect(pte.isValid());
    try std.testing.expect(pte.isBranch());
    try std.testing.expect(!pte.isLeaf());
    try std.testing.expectEqual(@as(usize, 0x80000000), pte.physAddr());
}

test "Pte.kernelLeaf creates valid leaf entry" {
    const pte = Pte.kernelLeaf(0x80200000, true, true);
    try std.testing.expect(pte.isValid());
    try std.testing.expect(pte.isLeaf());
    try std.testing.expect(!pte.isBranch());
    try std.testing.expect(pte.r);
    try std.testing.expect(pte.w);
    try std.testing.expect(pte.x);
    try std.testing.expect(pte.g);
    try std.testing.expect(!pte.u);
}

test "Pte.userLeaf creates valid user entry" {
    const pte = Pte.userLeaf(0x1000, false, false);
    try std.testing.expect(pte.isValid());
    try std.testing.expect(pte.isLeaf());
    try std.testing.expect(pte.r); // Always readable
    try std.testing.expect(pte.u);
    try std.testing.expect(!pte.g);
}

test "VirtAddr.parse extracts correct indices" {
    const va = VirtAddr.parse(0x80200000);
    try std.testing.expectEqual(@as(u9, 2), va.vpn2);
    try std.testing.expectEqual(@as(u9, 1), va.vpn1);
    try std.testing.expectEqual(@as(u9, 0), va.vpn0);
    try std.testing.expectEqual(@as(u12, 0), va.offset);
}

test "VirtAddr.isCanonical validates addresses" {
    try std.testing.expect(VirtAddr.isCanonical(0x0));
    try std.testing.expect(VirtAddr.isCanonical(0x3FFFFFFFFF));
    try std.testing.expect(VirtAddr.isCanonical(0xFFFFFFC000000000));
    try std.testing.expect(!VirtAddr.isCanonical(0x4000000000));
}

test "Satp.sv39 creates correct value" {
    const satp = Satp.sv39(0x80000000, 5);
    try std.testing.expectEqual(@as(u4, 8), satp.mode);
    try std.testing.expectEqual(@as(u16, 5), satp.asid);
    try std.testing.expectEqual(@as(u44, 0x80000), satp.ppn);
}

test "PageTable size matches page size" {
    try std.testing.expectEqual(PAGE_SIZE, @sizeOf(PageTable));
}

test "translate handles gigapage mappings" {
    var root = PageTable.EMPTY;
    root.entries[2] = Pte.kernelLeaf(0x80000000, true, true); // 1GB gigapage at index 2

    // Address in middle of gigapage should translate correctly
    const pa = translate(&root, 0x80123456);
    try std.testing.expectEqual(@as(?usize, 0x80123456), pa);

    // Unmapped address returns null
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x40000000));
}

test "mapPage returns NotAligned for misaligned addresses" {
    var root = PageTable.EMPTY;

    // Misaligned virtual address
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1001, 0x2000, .{}));

    // Misaligned physical address
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1000, 0x2001, .{}));
}

test "mapPage returns TableNotPresent without intermediate tables" {
    var root = PageTable.EMPTY;

    // No level 2 entry present
    try std.testing.expectError(MapError.TableNotPresent, mapPage(&root, 0x80001000, 0x90001000, .{}));
}

test "walk returns null for unmapped address" {
    var root = PageTable.EMPTY;
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x80001000));
}

test "walk returns null for gigapage mapping" {
    var root = PageTable.EMPTY;
    root.entries[2] = Pte.kernelLeaf(0x80000000, true, true);

    // Gigapage mapping - can't walk to page level
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x80001000));
}

test "physToVirt adds KERNEL_VIRT_BASE" {
    // Physical 0x80200000 should map to virtual 0xFFFF_FFC0_8020_0000
    const virt = physToVirt(0x80200000);
    try std.testing.expectEqual(@as(usize, 0xFFFF_FFC0_8020_0000), virt);
}

test "virtToPhys subtracts KERNEL_VIRT_BASE" {
    // Virtual 0xFFFF_FFC0_8020_0000 should map to physical 0x80200000
    const phys = virtToPhys(0xFFFF_FFC0_8020_0000);
    try std.testing.expectEqual(@as(usize, 0x80200000), phys);
}

test "physToVirt and virtToPhys are inverses" {
    const original: usize = 0x80200000;
    const round_trip = virtToPhys(physToVirt(original));
    try std.testing.expectEqual(original, round_trip);
}
