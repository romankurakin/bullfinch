//! RISC-V Sv48 Memory Management Unit.
//!
//! Sv48 provides 48-bit virtual addresses with a 4-level page table. The format is:
//! VPN[3](9b) | VPN[2](9b) | VPN[1](9b) | VPN[0](9b) | offset(12b). Each level
//! indexes into a 512-entry table (4KB page = 512 × 8-byte entries).
//!
//! Page table entries can be leaves (with RWX permissions) or branches (pointing to
//! the next level). A leaf at level 2 creates a 1GB gigapage, at level 1 a 2MB
//! megapage. Boot uses gigapages via a dedicated L2 table for 512GB physmap.
//!
//! The SATP register holds the root page table address and ASID. The ASID field
//! allows per-process TLB entries without full flushes on context switch.
//!
//! See RISC-V Privileged Specification, Sections 12.3-12.6 (Virtual Memory).
//!
//! TODO(smp): Implement per-hart page table locks.
//! TODO(smp): Send IPI to other harts for TLB shootdown via SBI.
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

/// Kernel virtual base address (Sv48 upper canonical).
/// Physical addresses are mapped to virtual = physical + KERNEL_VIRT_BASE.
/// This is the lowest address in upper canonical range (bit 47 = 1).
pub const KERNEL_VIRT_BASE: usize = 0xFFFF_8000_0000_0000;

/// Offset from KERNEL_VIRT_BASE for kernel stack region.
/// Must be beyond physmap (RAM). 8GB offset supports systems up to 8GB RAM.
/// Stays within L3[256] (physmap) to use existing page table hierarchy.
pub const KSTACK_REGION_OFFSET: usize = 8 * (1 << 30); // 8GB

/// Highest exclusive address in lower canonical range (bit 47 = 0).
const LOWER_CANONICAL_LIMIT: usize = @as(usize, 1) << 47;

const GIGAPAGE_SIZE: usize = 1 << 30;
const GIGAPAGE_MASK: usize = GIGAPAGE_SIZE - 1;
const MEGAPAGE_SIZE: usize = 1 << 21;
const MEGAPAGE_MASK: usize = MEGAPAGE_SIZE - 1;

/// Convert physical address to kernel virtual address.
pub inline fn physToVirt(paddr: usize) usize {
    return paddr +% KERNEL_VIRT_BASE;
}

/// Convert kernel virtual address to physical address.
pub inline fn virtToPhys(vaddr: usize) usize {
    return vaddr -% KERNEL_VIRT_BASE;
}

/// Sv48 Page Table Entry (8 bytes).
/// Leaf vs branch: if any of read/write/execute set, it's a leaf (final translation).
/// If valid=1 and read=write=execute=0, it's a branch (pointer to next level).
pub const PageTableEntry = packed struct(u64) {
    v: bool = false, // Valid
    r: bool = false, // Read permission
    w: bool = false, // Write permission
    x: bool = false, // Execute permission
    u: bool = false, // User accessible
    g: bool = false, // Global (persists across address space switch)
    a: bool = false, // Accessed (set by hardware or software)
    d: bool = false, // Dirty (set by hardware or software on write)
    rsw: u2 = 0, // Reserved for software
    ppn: u44 = 0, // Physical page number
    reserved: u10 = 0, // Reserved, must be zero

    pub const INVALID = PageTableEntry{};

    /// Check if this entry is valid (present in page table).
    pub inline fn isValid(self: PageTableEntry) bool {
        return self.v;
    }

    /// Check if this is a leaf entry (final translation with permissions).
    pub inline fn isLeaf(self: PageTableEntry) bool {
        return self.r or self.w or self.x;
    }

    /// Check if this is a branch entry (pointer to next level table).
    pub inline fn isBranch(self: PageTableEntry) bool {
        return self.v and !self.isLeaf();
    }

    /// Extract the physical address from this entry.
    pub inline fn physAddr(self: PageTableEntry) usize {
        return @as(usize, self.ppn) << PAGE_SHIFT;
    }

    /// Create a branch entry pointing to the next level page table.
    pub fn branch(phys_addr: usize) PageTableEntry {
        return .{ .v = true, .ppn = @truncate(phys_addr >> PAGE_SHIFT) };
    }

    /// Kernel leaf entry. Pre-sets A/D bits to avoid page faults on first access
    /// since we don't rely on Svadu hardware support.
    pub fn kernelLeaf(phys_addr: usize, write: bool, exec: bool) PageTableEntry {
        return .{
            .v = true,
            .r = true, // W=1 R=0 is reserved
            .w = write,
            .x = exec,
            .g = true, // Global - not flushed on ASID change
            .a = true, // Pre-set to avoid access fault
            .d = write, // Pre-set if writable to avoid store fault
            .ppn = @truncate(phys_addr >> PAGE_SHIFT),
        };
    }

    /// User leaf entry. Sets user-accessible bit and pre-sets A/D bits.
    pub fn userLeaf(phys_addr: usize, write: bool, exec: bool) PageTableEntry {
        return .{
            .v = true,
            .r = true, // W=1 R=0 is reserved
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
    if (@sizeOf(PageTableEntry) != 8) @compileError("PTE must be 8 bytes");
}

/// Page table containing 512 entries (one 4KB page).
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PageTableEntry,

    pub const EMPTY = PageTable{ .entries = [_]PageTableEntry{PageTableEntry.INVALID} ** ENTRIES_PER_TABLE };

    /// Read entry at given index.
    pub inline fn get(self: *const PageTable, index: usize) PageTableEntry {
        return self.entries[index];
    }

    /// Write entry at given index.
    pub inline fn set(self: *PageTable, index: usize, pte: PageTableEntry) void {
        self.entries[index] = pte;
    }
};

comptime {
    if (@sizeOf(PageTable) != PAGE_SIZE) @compileError("PageTable must be one page");
}

/// Sv48 virtual address parsing into page table indices.
pub const VirtualAddress = struct {
    vpn3: u9, // Bits 47:39 (L3, root)
    vpn2: u9, // Bits 38:30 (L2)
    vpn1: u9, // Bits 29:21 (L1)
    vpn0: u9, // Bits 20:12 (L0, leaf)
    offset: u12,

    /// Parse a virtual address into its component indices.
    pub inline fn parse(vaddr: usize) VirtualAddress {
        return .{
            .vpn3 = @truncate((vaddr >> 39) & 0x1FF),
            .vpn2 = @truncate((vaddr >> 30) & 0x1FF),
            .vpn1 = @truncate((vaddr >> 21) & 0x1FF),
            .vpn0 = @truncate((vaddr >> 12) & 0x1FF),
            .offset = @truncate(vaddr & 0xFFF),
        };
    }

    /// Check if address is in lower canonical range (user space).
    pub inline fn isUserRange(vaddr: usize) bool {
        return vaddr < LOWER_CANONICAL_LIMIT;
    }

    /// Check if address is in upper canonical range (kernel space).
    pub inline fn isKernel(vaddr: usize) bool {
        return vaddr >= KERNEL_VIRT_BASE;
    }

    /// Check if address is canonical (bits 63:48 are sign-extension of bit 47).
    pub inline fn isCanonical(vaddr: usize) bool {
        return isUserRange(vaddr) or isKernel(vaddr);
    }
};

/// SATP register (mode + address space ID + root physical page number).
pub const SupervisorAddressTranslation = packed struct(u64) {
    ppn: u44, // Physical page number of root table
    asid: u16, // Address space identifier
    mode: u4, // Translation mode (0=bare, 8=Sv39, 9=Sv48)

    pub const MODE_BARE: u4 = 0;
    pub const MODE_SV39: u4 = 8;
    pub const MODE_SV48: u4 = 9;

    /// Create SATP value for Sv48 mode with given root table and address space ID.
    pub fn sv48(root_phys: usize, asid: u16) SupervisorAddressTranslation {
        return .{ .ppn = @truncate(root_phys >> PAGE_SHIFT), .asid = asid, .mode = MODE_SV48 };
    }

    /// Create SATP value for bare mode (MMU disabled).
    pub fn bare() SupervisorAddressTranslation {
        return .{ .ppn = 0, .asid = 0, .mode = MODE_BARE };
    }

    /// Read current SATP register value.
    pub fn read() SupervisorAddressTranslation {
        return @bitCast(asm volatile ("csrr %[ret], satp"
            : [ret] "=r" (-> u64),
        ));
    }

    /// Write SATP register to change address translation mode.
    pub fn write(self: SupervisorAddressTranslation) void {
        asm volatile ("csrw satp, %[val]"
            :
            : [val] "r" (@as(u64, @bitCast(self))),
        );
    }
};

comptime {
    if (@sizeOf(SupervisorAddressTranslation) != 8) @compileError("SATP must be 8 bytes");
}

/// Memory barrier for page table updates.
/// Required after PTE writes to ensure visibility before sfence.vma.
inline fn fence() void {
    cpu.fenceRwRw();
}

// Note: sfence.vma is local-only on RISC-V.
// TODO(smp): After secondary harts are online, send IPI via SBI for TLB shootdown.

pub const TranslationLookasideBuffer = struct {
    /// Invalidate all cached address translations (local hart only).
    /// TODO(smp): Send IPI to other harts to trigger remote sfence.
    pub inline fn flushAll() void {
        fence();
        asm volatile ("sfence.vma zero, zero");
    }

    /// Invalidate cached translation for a specific virtual address (local hart only).
    /// TODO(smp): Send IPI to other harts for address-specific shootdown.
    pub inline fn flushAddr(vaddr: usize) void {
        fence();
        asm volatile ("sfence.vma %[addr], zero"
            :
            : [addr] "r" (vaddr),
        );
    }

    /// Invalidate TLB on this hart only.
    /// Same as flushAll since sfence.vma is hart-local.
    pub inline fn flushLocal() void {
        fence();
        asm volatile ("sfence.vma zero, zero");
    }

    /// Invalidate all cached translations for a specific address space.
    /// TODO(smp): Use this for efficient process teardown with ASID.
    pub inline fn flushAsid(asid: u16) void {
        fence();
        asm volatile ("sfence.vma zero, %[asid]"
            :
            : [asid] "r" (@as(usize, asid)),
        );
    }

    /// Invalidate cached translation for a specific virtual address and address space.
    pub inline fn flushAddrAsid(vaddr: usize, asid: u16) void {
        fence();
        asm volatile ("sfence.vma %[addr], %[asid]"
            :
            : [addr] "r" (vaddr),
              [asid] "r" (@as(usize, asid)),
        );
    }
};

// TODO(smp): Page table operations need external locking for SMP.
/// Walk page tables for a virtual address and return pointer to the leaf entry.
/// Returns null if any level has an invalid entry or if a superpage is found
/// before reaching level 0. Only walks to level 0 (4KB page).
pub fn walk(root: *PageTable, vaddr: usize) ?*PageTableEntry {
    if (!VirtualAddress.isCanonical(vaddr)) return null;

    const va = VirtualAddress.parse(vaddr);

    // Level 3 (root)
    const l3_entry = &root.entries[va.vpn3];
    if (!l3_entry.isValid()) return null;
    if (l3_entry.isLeaf()) return null; // terapage, not page-level

    // Level 2
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l3_entry.physAddr()));
    const l2_entry = &l2_table.entries[va.vpn2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isLeaf()) return null; // gigapage, not page-level

    // Level 1
    const l1_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l1_entry = &l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isLeaf()) return null; // megapage, not page-level

    // Level 0
    const l0_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    return &l0_table.entries[va.vpn0];
}

/// Translate virtual address to physical address.
/// Handles superpages at any level as well as regular pages.
/// Returns null if address is not mapped.
pub fn translate(root: *PageTable, vaddr: usize) ?usize {
    if (!VirtualAddress.isCanonical(vaddr)) return null;

    const va = VirtualAddress.parse(vaddr);
    const TERAPAGE_MASK: usize = (1 << 39) - 1;

    // Level 3 (root)
    const l3_entry = root.entries[va.vpn3];
    if (!l3_entry.isValid()) return null;
    if (l3_entry.isLeaf()) {
        return l3_entry.physAddr() | (vaddr & TERAPAGE_MASK);
    }

    // Level 2
    const l2_table: *const PageTable = @ptrFromInt(physToVirt(l3_entry.physAddr()));
    const l2_entry = l2_table.entries[va.vpn2];
    if (!l2_entry.isValid()) return null;
    if (l2_entry.isLeaf()) {
        return l2_entry.physAddr() | (vaddr & GIGAPAGE_MASK);
    }

    // Level 1
    const l1_table: *const PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l1_entry = l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) return null;
    if (l1_entry.isLeaf()) {
        return l1_entry.physAddr() | (vaddr & MEGAPAGE_MASK);
    }

    // Level 0
    const l0_table: *const PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l0_entry = l0_table.entries[va.vpn0];
    if (!l0_entry.isValid()) return null;

    return l0_entry.physAddr() | @as(usize, va.offset);
}

/// Map a 4KB page at the given virtual address.
/// Requires all intermediate page tables (L3, L2, L1) to already exist.
/// Does NOT flush TLB - caller must do that after mapping.
///
/// TODO(smp): Caller must hold page table lock.
pub fn mapPage(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags) MapError!void {
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtualAddress.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtualAddress.parse(vaddr);

    // Level 3 (root) - must be a branch entry
    const l3_entry = root.entries[va.vpn3];
    if (!l3_entry.isValid()) return MapError.TableNotPresent;
    if (l3_entry.isLeaf()) return MapError.SuperpageConflict;

    // Level 2 - must be a branch entry
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l3_entry.physAddr()));
    const l2_entry = l2_table.entries[va.vpn2];
    if (!l2_entry.isValid()) return MapError.TableNotPresent;
    if (l2_entry.isLeaf()) return MapError.SuperpageConflict;

    // Level 1 - must be a branch entry
    const l1_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    const l1_entry = l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) return MapError.TableNotPresent;
    if (l1_entry.isLeaf()) return MapError.SuperpageConflict;

    // Level 0 - the actual page entry
    const l0_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l0_entry = &l0_table.entries[va.vpn0];
    if (l0_entry.isValid()) return MapError.AlreadyMapped;

    if (flags.user) {
        l0_entry.* = PageTableEntry.userLeaf(paddr, flags.write, flags.exec);
    } else {
        l0_entry.* = PageTableEntry.kernelLeaf(paddr, flags.write, flags.exec);
    }
    fence();
}

/// Function type for page table allocation.
/// Must return virtual address of a zeroed page, or null on OOM.
pub const PageAllocFn = *const fn () ?usize;

/// Map a 4KB page, allocating intermediate tables as needed.
/// alloc_page must return virtual address of a zeroed page.
/// Does NOT flush TLB - caller must do that after mapping.
///
/// TODO(smp): Caller must hold page table lock.
pub fn mapPageWithAlloc(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags, alloc_page: PageAllocFn) MapError!void {
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtualAddress.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtualAddress.parse(vaddr);

    // Level 3 (root) - allocate L2 table if needed
    var l3_entry = &root.entries[va.vpn3];
    if (!l3_entry.isValid()) {
        const l2_virt = alloc_page() orelse return MapError.OutOfMemory;
        l3_entry.* = PageTableEntry.branch(virtToPhys(l2_virt));
        fence();
    } else if (l3_entry.isLeaf()) {
        return MapError.SuperpageConflict;
    }

    // Level 2 - allocate L1 table if needed
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l3_entry.physAddr()));
    var l2_entry = &l2_table.entries[va.vpn2];
    if (!l2_entry.isValid()) {
        const l1_virt = alloc_page() orelse return MapError.OutOfMemory;
        l2_entry.* = PageTableEntry.branch(virtToPhys(l1_virt));
        fence();
    } else if (l2_entry.isLeaf()) {
        return MapError.SuperpageConflict;
    }

    // Level 1 - allocate L0 table if needed
    const l1_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    var l1_entry = &l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) {
        const l0_virt = alloc_page() orelse return MapError.OutOfMemory;
        l1_entry.* = PageTableEntry.branch(virtToPhys(l0_virt));
        fence();
    } else if (l1_entry.isLeaf()) {
        return MapError.SuperpageConflict;
    }

    // Level 0 - the actual page entry
    const l0_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l0_entry = &l0_table.entries[va.vpn0];
    if (l0_entry.isValid()) return MapError.AlreadyMapped;

    if (flags.user) {
        l0_entry.* = PageTableEntry.userLeaf(paddr, flags.write, flags.exec);
    } else {
        l0_entry.* = PageTableEntry.kernelLeaf(paddr, flags.write, flags.exec);
    }
    fence();
}

/// Unmap a 4KB page at the given virtual address.
/// Returns the physical address that was mapped.
/// Does NOT flush TLB - caller must do that after unmapping (allows batching).
///
/// TODO(smp): Caller must hold page table lock.
pub fn unmapPage(root: *PageTable, vaddr: usize) UnmapError!usize {
    if (!VirtualAddress.isCanonical(vaddr)) return UnmapError.NotCanonical;

    const entry = walk(root, vaddr) orelse return UnmapError.NotMapped;
    if (!entry.isValid()) return UnmapError.NotMapped;

    const paddr = entry.physAddr();
    entry.* = PageTableEntry.INVALID;
    fence();
    return paddr;
}

/// Unmap a 4KB page and immediately flush TLB for that address.
/// Convenience wrapper when batching is not needed.
pub fn unmapPageAndFlush(root: *PageTable, vaddr: usize) UnmapError!usize {
    const paddr = try unmapPage(root, vaddr);
    TranslationLookasideBuffer.flushAddr(vaddr);
    return paddr;
}

// These functions run during early boot on the primary hart only.
// No locking needed - secondary harts are not running yet.

var root_table: PageTable align(PAGE_SIZE) = PageTable.EMPTY; // L3
var l2_identity_table: PageTable align(PAGE_SIZE) = PageTable.EMPTY; // L2 for identity mapping
var l2_physmap_table: PageTable align(PAGE_SIZE) = PageTable.EMPTY; // L2 for kernel physmap

/// Maximum physmap entries (512 gigapages = 512GB).
/// L3 entry 256 points to l2_physmap_table with 512 entries.
const MAX_PHYSMAP_ENTRIES: usize = ENTRIES_PER_TABLE;

/// VPN3 index for kernel higher-half (bit 47 = 1).
const KERNEL_VPN3: usize = (KERNEL_VIRT_BASE >> 39) & 0x1FF; // 256

var stored_kernel_phys_load: usize = 0;
var physmap_end_gb: usize = 0;

/// Set up identity + higher-half mappings using 1GB gigapages, enable Sv48.
/// Creates minimal mapping covering kernel and DTB. Call expandPhysmap()
/// after reading DTB to map remaining RAM.
///
/// BOOT-TIME ONLY: Called from physInit() on primary hart before SMP.
pub fn init(kernel_phys_load: usize, dtb_ptr: usize) void {
    stored_kernel_phys_load = kernel_phys_load;

    // Calculate mapping to cover both kernel and DTB
    const map_start = if (dtb_ptr > 0) @min(kernel_phys_load, dtb_ptr) else kernel_phys_load;
    const dtb_end = if (dtb_ptr > 0) dtb_ptr + DTB_MAX_SIZE else kernel_phys_load;
    const map_end = @max(kernel_phys_load + MIN_PHYSMAP_SIZE, dtb_end);
    const start_gb = map_start >> 30;
    const end_gb = (map_end + (1 << 30) - 1) >> 30;
    physmap_end_gb = end_gb;

    // L2 identity table: gigapages for boot continuation after MMU enable
    l2_identity_table.entries[0] = PageTableEntry.kernelLeaf(0, true, false); // MMIO (first GB)

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l2_identity_table.entries[gb] = PageTableEntry.kernelLeaf(gb << 30, true, true);
    }

    // L2 physmap table: gigapages for kernel higher-half
    l2_physmap_table.entries[0] = PageTableEntry.kernelLeaf(0, true, false); // MMIO in higher-half

    gb = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l2_physmap_table.entries[gb] = PageTableEntry.kernelLeaf(gb << 30, true, true);
    }

    // L3 root table: branches to L2 tables
    root_table.entries[0] = PageTableEntry.branch(@intFromPtr(&l2_identity_table)); // Identity
    root_table.entries[KERNEL_VPN3] = PageTableEntry.branch(@intFromPtr(&l2_physmap_table)); // Kernel

    fence();
    SupervisorAddressTranslation.sv48(@intFromPtr(&root_table), 0).write();
    TranslationLookasideBuffer.flushAll();
}

/// Expand physmap to cover all RAM. Called after DTB is readable.
/// Uses 1GB gigapages in l2_physmap_table.
///
/// BOOT-TIME ONLY: Called from virtInit() on primary hart before SMP.
pub fn expandPhysmap(ram_size: usize) void {
    const new_end = stored_kernel_phys_load + ram_size;
    const new_end_gb = @min((new_end + (1 << 30) - 1) >> 30, MAX_PHYSMAP_ENTRIES);

    var gb = physmap_end_gb;
    while (gb < new_end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l2_physmap_table.entries[gb] = PageTableEntry.kernelLeaf(gb << 30, true, true);
    }

    if (new_end_gb > physmap_end_gb) {
        TranslationLookasideBuffer.flushAll();
        physmap_end_gb = new_end_gb;
    }
}

/// Disable MMU. Only safe if running from identity-mapped region.
pub fn disable() void {
    fence();
    SupervisorAddressTranslation.bare().write();
    TranslationLookasideBuffer.flushAll();
}

/// Return pointer to kernel page table (L3 root, which covers both identity and kernel).
/// Used for mapping kernel stack pages with guard pages.
pub fn getKernelPageTable() *PageTable {
    return &root_table;
}

/// Remove identity mapping after transitioning to higher-half.
/// Clears L3 entry 0 which points to l2_identity_table (the entire lower-half).
/// Improves security by preventing kernel access via low addresses.
pub fn removeIdentityMapping() void {
    root_table.entries[0] = PageTableEntry.INVALID;
    TranslationLookasideBuffer.flushAll();
}

/// Post-MMU initialization for RISC-V.
/// Reloads Global Pointer (gp) register to point to virtual addresses.
/// GP was set during physical boot; must be updated after MMU enables higher-half.
pub fn postMmuInit() void {
    asm volatile (
        \\ .option push
        \\ .option norelax
        \\ la gp, __global_pointer$
        \\ .option pop
    );
}

test "validates PageTableEntry size and layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(PageTableEntry));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(PageTableEntry));
}

test "sets PageTableEntry.INVALID to all zeros" {
    const invalid: u64 = @bitCast(PageTableEntry.INVALID);
    try std.testing.expectEqual(@as(u64, 0), invalid);
}

test "creates valid PageTableEntry.branch entry" {
    const pte = PageTableEntry.branch(0x80000000);
    try std.testing.expect(pte.isValid());
    try std.testing.expect(pte.isBranch());
    try std.testing.expect(!pte.isLeaf());
    try std.testing.expectEqual(@as(usize, 0x80000000), pte.physAddr());
}

test "creates valid PageTableEntry.kernelLeaf entry" {
    const pte = PageTableEntry.kernelLeaf(0x80200000, true, true);
    try std.testing.expect(pte.isValid());
    try std.testing.expect(pte.isLeaf());
    try std.testing.expect(!pte.isBranch());
    try std.testing.expect(pte.r);
    try std.testing.expect(pte.w);
    try std.testing.expect(pte.x);
    try std.testing.expect(pte.g);
    try std.testing.expect(!pte.u);
}

test "creates valid PageTableEntry.userLeaf entry" {
    const pte = PageTableEntry.userLeaf(0x1000, false, false);
    try std.testing.expect(pte.isValid());
    try std.testing.expect(pte.isLeaf());
    try std.testing.expect(pte.r);
    try std.testing.expect(pte.u);
    try std.testing.expect(!pte.g);
}

test "extracts correct indices in VirtualAddress.parse" {
    // Low address: 0x80200000 = 2GB + 2MB
    const va = VirtualAddress.parse(0x80200000);
    try std.testing.expectEqual(@as(u9, 0), va.vpn3);
    try std.testing.expectEqual(@as(u9, 2), va.vpn2);
    try std.testing.expectEqual(@as(u9, 1), va.vpn1);
    try std.testing.expectEqual(@as(u9, 0), va.vpn0);
    try std.testing.expectEqual(@as(u12, 0), va.offset);

    // Kernel address
    const kva = VirtualAddress.parse(KERNEL_VIRT_BASE + 0x80200000);
    try std.testing.expectEqual(@as(u9, 256), kva.vpn3); // KERNEL_VPN3
    try std.testing.expectEqual(@as(u9, 2), kva.vpn2);
    try std.testing.expectEqual(@as(u9, 1), kva.vpn1);
    try std.testing.expectEqual(@as(u9, 0), kva.vpn0);
}

test "validates addresses in VirtualAddress.isCanonical" {
    // Sv48: canonical if bits 63:47 are all same as bit 47
    // Lower canonical: 0 to 0x7FFF_FFFF_FFFF (128TB - 1)
    try std.testing.expect(VirtualAddress.isCanonical(0x0));
    try std.testing.expect(VirtualAddress.isCanonical(0x7FFF_FFFF_FFFF)); // Max lower canonical

    // Upper canonical: 0xFFFF_8000_0000_0000 to max
    try std.testing.expect(VirtualAddress.isCanonical(KERNEL_VIRT_BASE));
    try std.testing.expect(VirtualAddress.isCanonical(0xFFFF_FFFF_FFFF_FFFF));

    // Non-canonical (hole)
    try std.testing.expect(!VirtualAddress.isCanonical(0x8000_0000_0000)); // Just above lower
    try std.testing.expect(!VirtualAddress.isCanonical(0xFFFF_7FFF_FFFF_FFFF)); // Just below upper
}

test "creates correct SupervisorAddressTranslation.sv48 value" {
    const satp = SupervisorAddressTranslation.sv48(0x80000000, 5);
    try std.testing.expectEqual(@as(u4, SupervisorAddressTranslation.MODE_SV48), satp.mode);
    try std.testing.expectEqual(@as(u16, 5), satp.asid);
    try std.testing.expectEqual(@as(u44, 0x80000), satp.ppn);
}

test "matches PageTable size to page size" {
    try std.testing.expectEqual(PAGE_SIZE, @sizeOf(PageTable));
}

test "translates terapage mappings" {
    // Sv48: terapage at L3 (512GB)
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelLeaf(0x8000000000, true, true); // 512GB terapage at vpn3=1

    // Address with vpn3=1 maps through terapage
    const pa = translate(&root, 0x8000123456);
    try std.testing.expectEqual(@as(?usize, 0x8000123456), pa);

    // Unmapped L3 entry
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x10000000000)); // vpn3=2
}

test "returns null for non-canonical addresses in translate" {
    var root = PageTable.EMPTY;
    // Non-canonical address (in Sv48 hole)
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x8000_0000_0000));
}

test "returns NotAligned for misaligned addresses in mapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1001, 0x2000, .{}));
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1000, 0x2001, .{}));
}

test "returns NotCanonical for non-canonical addresses in mapPage" {
    var root = PageTable.EMPTY;
    // Sv48 non-canonical (in hole)
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x8000_0000_0000, 0x1000, .{}));
}

test "mapPage returns SuperpageConflict for terapage mappings" {
    // Sv48: terapage at L3 (512GB)
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelLeaf(0x8000000000, true, true); // 512GB terapage at vpn3=1

    // Try to map 4KB page within the terapage
    try std.testing.expectError(MapError.SuperpageConflict, mapPage(&root, 0x8000001000, 0x9000001000, .{}));
}

test "returns TableNotPresent without intermediate tables in mapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.TableNotPresent, mapPage(&root, 0x80001000, 0x90001000, .{}));
}

test "returns null for unmapped address in walk" {
    var root = PageTable.EMPTY;
    try std.testing.expectEqual(@as(?*PageTableEntry, null), walk(&root, 0x80001000));
}

test "returns null for terapage mapping in walk" {
    // Sv48: terapage at L3 (not walkable to L0)
    var root = PageTable.EMPTY;
    root.entries[1] = PageTableEntry.kernelLeaf(0x8000000000, true, true); // 512GB terapage at vpn3=1

    // Walk stops at terapage, returns null (no L0 entry)
    try std.testing.expectEqual(@as(?*PageTableEntry, null), walk(&root, 0x8000001000));
}

test "adds KERNEL_VIRT_BASE in physToVirt" {
    const virt = physToVirt(0x80200000);
    try std.testing.expectEqual(@as(usize, KERNEL_VIRT_BASE + 0x80200000), virt);
}

test "subtracts KERNEL_VIRT_BASE in virtToPhys" {
    const phys = virtToPhys(KERNEL_VIRT_BASE + 0x80200000);
    try std.testing.expectEqual(@as(usize, 0x80200000), phys);
}

test "treats physToVirt and virtToPhys as inverses" {
    const original: usize = 0x80200000;
    const round_trip = virtToPhys(physToVirt(original));
    try std.testing.expectEqual(original, round_trip);
}

test "returns NotMapped for unmapped address in unmapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(UnmapError.NotMapped, unmapPage(&root, 0x80001000));
}

test "returns NotCanonical for non-canonical addresses in unmapPage" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(UnmapError.NotCanonical, unmapPage(&root, 0x8000_0000_0000));
}
