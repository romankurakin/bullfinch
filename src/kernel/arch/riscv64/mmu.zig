//! RISC-V Sv48 Memory Management Unit.
//!
//! RISC-V Sv48 provides 48-bit virtual addresses with a 4-level page table. The format
//! is: VPN[3](9b) | VPN[2](9b) | VPN[1](9b) | VPN[0](9b) | offset(12b). Each level
//! indexes into a 512-entry table (4KB page = 512 × 8-byte entries).
//!
//! Page table entries can be leaves (with RWX permissions) or branches (pointing to
//! the next level). A leaf at level 2 creates a 1GB gigapage, at level 1 a 2MB
//! megapage. Boot uses gigapages via a dedicated L2 table for 512GB physmap.
//!
//! RISC-V uses a single SATP register for translation, unlike ARM's TTBR0/TTBR1 split.
//! The ASID field in SATP allows per-process TLB entries without full flushes.
//!
//! See RISC-V Privileged Specification, Chapter 5 (Supervisor-Level ISA).
//!
//! TODO(smp): Implement per-hart page table locks
//! TODO(smp): Send IPI to other harts for TLB shootdown via SBI
//! TODO(smp): Use ASID for per-process TLB management (currently ASID=0)

const builtin = @import("builtin");
const std = @import("std");

const memory = @import("../../memory/memory.zig");
const mmu_types = @import("../../mmu/mmu.zig");

const is_riscv64 = builtin.cpu.arch == .riscv64;

pub const PAGE_SIZE = memory.PAGE_SIZE;
pub const PAGE_SHIFT = memory.PAGE_SHIFT;
pub const ENTRIES_PER_TABLE = memory.ENTRIES_PER_TABLE;
pub const PageFlags = mmu_types.PageFlags;
pub const MapError = mmu_types.MapError;
pub const UnmapError = mmu_types.UnmapError;

/// Kernel virtual base address (Sv48 upper canonical).
/// Physical addresses are mapped to virtual = physical + KERNEL_VIRT_BASE.
/// This is the lowest address in upper canonical range (bit 47 = 1).
pub const KERNEL_VIRT_BASE: usize = 0xFFFF_8000_0000_0000;

const GIGAPAGE_SIZE: usize = 1 << 30;
const GIGAPAGE_MASK: usize = GIGAPAGE_SIZE - 1;
const MEGAPAGE_SIZE: usize = 1 << 21;
const MEGAPAGE_MASK: usize = MEGAPAGE_SIZE - 1;

/// Convert physical address to kernel virtual address.
pub noinline fn physToVirt(paddr: usize) usize {
    return paddr +% KERNEL_VIRT_BASE;
}

/// Convert kernel virtual address to physical address.
pub inline fn virtToPhys(vaddr: usize) usize {
    return vaddr -% KERNEL_VIRT_BASE;
}

/// Sv48 Page Table Entry (8 bytes).
/// Leaf vs branch: if any of read/write/execute set, it's a leaf (final translation).
/// If valid=1 and read=write=execute=0, it's a branch (pointer to next level).
pub const Pte = packed struct(u64) {
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

    pub const INVALID = Pte{};

    /// Check if this entry is valid (present in page table).
    pub inline fn isValid(self: Pte) bool {
        return self.v;
    }

    /// Check if this is a leaf entry (final translation with permissions).
    pub inline fn isLeaf(self: Pte) bool {
        return self.r or self.w or self.x;
    }

    /// Check if this is a branch entry (pointer to next level table).
    pub inline fn isBranch(self: Pte) bool {
        return self.v and !self.isLeaf();
    }

    /// Extract the physical address from this entry.
    pub inline fn physAddr(self: Pte) usize {
        return @as(usize, self.ppn) << PAGE_SHIFT;
    }

    /// Create a branch entry pointing to the next level page table.
    pub fn branch(phys_addr: usize) Pte {
        return .{ .v = true, .ppn = @truncate(phys_addr >> PAGE_SHIFT) };
    }

    /// Kernel leaf entry. Pre-sets A/D bits to avoid page faults on first access
    /// since we don't rely on Svadu hardware support.
    pub fn kernelLeaf(phys_addr: usize, write: bool, exec: bool) Pte {
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
    pub fn userLeaf(phys_addr: usize, write: bool, exec: bool) Pte {
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
    if (@sizeOf(Pte) != 8) @compileError("PTE must be 8 bytes");
}

/// Page table containing 512 entries (one 4KB page).
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]Pte,

    pub const EMPTY = PageTable{ .entries = [_]Pte{Pte.INVALID} ** ENTRIES_PER_TABLE };

    /// Read entry at given index.
    pub inline fn get(self: *const PageTable, index: usize) Pte {
        return self.entries[index];
    }

    /// Write entry at given index.
    pub inline fn set(self: *PageTable, index: usize, pte: Pte) void {
        self.entries[index] = pte;
    }
};

comptime {
    if (@sizeOf(PageTable) != PAGE_SIZE) @compileError("PageTable must be one page");
}

/// Sv48 virtual address parsing into page table indices.
pub const VirtAddr = struct {
    vpn3: u9, // Bits 47:39 (L3, root)
    vpn2: u9, // Bits 38:30 (L2)
    vpn1: u9, // Bits 29:21 (L1)
    vpn0: u9, // Bits 20:12 (L0, leaf)
    offset: u12,

    /// Parse a virtual address into its component indices.
    pub inline fn parse(vaddr: usize) VirtAddr {
        return .{
            .vpn3 = @truncate((vaddr >> 39) & 0x1FF),
            .vpn2 = @truncate((vaddr >> 30) & 0x1FF),
            .vpn1 = @truncate((vaddr >> 21) & 0x1FF),
            .vpn0 = @truncate((vaddr >> 12) & 0x1FF),
            .offset = @truncate(vaddr & 0xFFF),
        };
    }

    /// Check if address is canonical (bits 63:48 are sign-extension of bit 47).
    pub inline fn isCanonical(vaddr: usize) bool {
        const high_bits = vaddr >> 47;
        return high_bits == 0 or high_bits == 0x1FFFF;
    }
};

/// SATP register (mode + address space ID + root physical page number).
pub const Satp = packed struct(u64) {
    ppn: u44, // Physical page number of root table
    asid: u16, // Address space identifier
    mode: u4, // Translation mode (0=bare, 8=Sv39, 9=Sv48)

    pub const MODE_BARE: u4 = 0;
    pub const MODE_SV39: u4 = 8;
    pub const MODE_SV48: u4 = 9;

    /// Create SATP value for Sv48 mode with given root table and address space ID.
    pub fn sv48(root_phys: usize, asid: u16) Satp {
        return .{ .ppn = @truncate(root_phys >> PAGE_SHIFT), .asid = asid, .mode = MODE_SV48 };
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
        if (is_riscv64) asm volatile ("csrw satp, %[val]"
            :
            : [val] "r" (@as(u64, @bitCast(self))),
        );
    }
};

comptime {
    if (@sizeOf(Satp) != 8) @compileError("SATP must be 8 bytes");
}

/// Memory barrier for page table updates.
/// Required after PTE writes to ensure visibility before sfence.vma.
inline fn fence() void {
    if (is_riscv64) asm volatile ("fence rw, rw");
}

// Note: sfence.vma is local-only on RISC-V.
// TODO(smp): After secondary harts are online, send IPI via SBI for TLB shootdown.

pub const Tlb = struct {
    /// Invalidate all cached address translations (local hart only).
    /// TODO(smp): Send IPI to other harts to trigger remote sfence.
    pub inline fn flushAll() void {
        fence();
        if (is_riscv64) asm volatile ("sfence.vma zero, zero");
    }

    /// Invalidate cached translation for a specific virtual address (local hart only).
    /// TODO(smp): Send IPI to other harts for address-specific shootdown.
    pub inline fn flushAddr(vaddr: usize) void {
        fence();
        if (is_riscv64) asm volatile ("sfence.vma %[addr], zero"
            :
            : [addr] "r" (vaddr),
        );
    }

    /// Invalidate TLB on this hart only (alias for flushAll on RISC-V).
    /// Provided for API consistency with ARM64.
    pub inline fn flushLocal() void {
        fence();
        if (is_riscv64) asm volatile ("sfence.vma zero, zero");
    }

    /// Invalidate all cached translations for a specific address space.
    /// TODO(smp): Use this for efficient process teardown with ASID.
    pub inline fn flushAsid(asid: u16) void {
        fence();
        if (is_riscv64) asm volatile ("sfence.vma zero, %[asid]"
            :
            : [asid] "r" (@as(usize, asid)),
        );
    }

    /// Invalidate cached translation for a specific virtual address and address space.
    pub inline fn flushAddrAsid(vaddr: usize, asid: u16) void {
        fence();
        if (is_riscv64) asm volatile ("sfence.vma %[addr], %[asid]"
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
pub fn walk(root: *PageTable, vaddr: usize) ?*Pte {
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);

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
    if (!VirtAddr.isCanonical(vaddr)) return null;

    const va = VirtAddr.parse(vaddr);
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
    if (!VirtAddr.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtAddr.parse(vaddr);

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
        l0_entry.* = Pte.userLeaf(paddr, flags.write, flags.exec);
    } else {
        l0_entry.* = Pte.kernelLeaf(paddr, flags.write, flags.exec);
    }
    fence();
}

/// Map a 4KB page, allocating intermediate tables as needed.
/// Allocator must provide zeroed pages (use page_allocator from PMM wrapper).
/// Does NOT flush TLB - caller must do that after mapping.
///
/// TODO(smp): Caller must hold page table lock.
pub fn mapPageWithAlloc(root: *PageTable, vaddr: usize, paddr: usize, flags: PageFlags, allocator: std.mem.Allocator) MapError!void {
    if ((vaddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if ((paddr & (PAGE_SIZE - 1)) != 0) return MapError.NotAligned;
    if (!VirtAddr.isCanonical(vaddr)) return MapError.NotCanonical;

    const va = VirtAddr.parse(vaddr);

    // Level 3 (root) - allocate L2 table if needed
    var l3_entry = &root.entries[va.vpn3];
    if (!l3_entry.isValid()) {
        const l2_phys = allocPageTable(allocator) orelse return MapError.OutOfMemory;
        l3_entry.* = Pte.branch(l2_phys);
        fence();
    } else if (l3_entry.isLeaf()) {
        return MapError.SuperpageConflict;
    }

    // Level 2 - allocate L1 table if needed
    const l2_table: *PageTable = @ptrFromInt(physToVirt(l3_entry.physAddr()));
    var l2_entry = &l2_table.entries[va.vpn2];
    if (!l2_entry.isValid()) {
        const l1_phys = allocPageTable(allocator) orelse return MapError.OutOfMemory;
        l2_entry.* = Pte.branch(l1_phys);
        fence();
    } else if (l2_entry.isLeaf()) {
        return MapError.SuperpageConflict;
    }

    // Level 1 - allocate L0 table if needed
    const l1_table: *PageTable = @ptrFromInt(physToVirt(l2_entry.physAddr()));
    var l1_entry = &l1_table.entries[va.vpn1];
    if (!l1_entry.isValid()) {
        const l0_phys = allocPageTable(allocator) orelse return MapError.OutOfMemory;
        l1_entry.* = Pte.branch(l0_phys);
        fence();
    } else if (l1_entry.isLeaf()) {
        return MapError.SuperpageConflict;
    }

    // Level 0 - the actual page entry
    const l0_table: *PageTable = @ptrFromInt(physToVirt(l1_entry.physAddr()));
    const l0_entry = &l0_table.entries[va.vpn0];
    if (l0_entry.isValid()) return MapError.AlreadyMapped;

    if (flags.user) {
        l0_entry.* = Pte.userLeaf(paddr, flags.write, flags.exec);
    } else {
        l0_entry.* = Pte.kernelLeaf(paddr, flags.write, flags.exec);
    }
    fence();
}

/// Allocate a zeroed page table using std.mem.Allocator.
/// Returns physical address or null on OOM.
fn allocPageTable(allocator: std.mem.Allocator) ?usize {
    const page = allocator.alignedAlloc(u8, PAGE_SIZE, PAGE_SIZE) catch return null;
    @memset(page, 0);
    return virtToPhys(@intFromPtr(page.ptr));
}

/// Unmap a 4KB page at the given virtual address.
/// Returns the physical address that was mapped.
/// Does NOT flush TLB - caller must do that after unmapping (allows batching).
///
/// TODO(smp): Caller must hold page table lock.
pub fn unmapPage(root: *PageTable, vaddr: usize) UnmapError!usize {
    if (!VirtAddr.isCanonical(vaddr)) return UnmapError.NotCanonical;

    const entry = walk(root, vaddr) orelse return UnmapError.NotMapped;
    if (!entry.isValid()) return UnmapError.NotMapped;

    const paddr = entry.physAddr();
    entry.* = Pte.INVALID;
    fence();
    return paddr;
}

/// Unmap a 4KB page and immediately flush TLB for that address.
/// Convenience wrapper when batching is not needed.
pub fn unmapPageAndFlush(root: *PageTable, vaddr: usize) UnmapError!usize {
    const paddr = try unmapPage(root, vaddr);
    Tlb.flushAddr(vaddr);
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
    const kernel_start = kernel_phys_load;
    const dtb_end = if (dtb_ptr > 0) dtb_ptr + (1 << 20) else kernel_phys_load;
    const map_end = @max(kernel_phys_load + (1 << 30), dtb_end);
    const start_gb = kernel_start >> 30;
    const end_gb = (map_end + (1 << 30) - 1) >> 30;
    physmap_end_gb = end_gb;

    // L2 identity table: gigapages for boot continuation after MMU enable
    l2_identity_table.entries[0] = Pte.kernelLeaf(0, true, false); // MMIO (first GB)

    var gb: usize = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l2_identity_table.entries[gb] = Pte.kernelLeaf(gb << 30, true, true);
    }

    // L2 physmap table: gigapages for kernel higher-half
    l2_physmap_table.entries[0] = Pte.kernelLeaf(0, true, false); // MMIO in higher-half

    gb = start_gb;
    while (gb < end_gb) : (gb += 1) {
        if (gb == 0) continue;
        l2_physmap_table.entries[gb] = Pte.kernelLeaf(gb << 30, true, true);
    }

    // L3 root table: branches to L2 tables
    root_table.entries[0] = Pte.branch(@intFromPtr(&l2_identity_table)); // Identity
    root_table.entries[KERNEL_VPN3] = Pte.branch(@intFromPtr(&l2_physmap_table)); // Kernel

    fence();
    Satp.sv48(@intFromPtr(&root_table), 0).write();
    Tlb.flushAll();
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
        l2_physmap_table.entries[gb] = Pte.kernelLeaf(gb << 30, true, true);
    }

    if (new_end_gb > physmap_end_gb) {
        Tlb.flushAll();
        physmap_end_gb = new_end_gb;
    }
}

/// Disable MMU. Only safe if running from identity-mapped region.
pub fn disable() void {
    fence();
    Satp.bare().write();
    Tlb.flushAll();
}

/// Remove identity mapping after transitioning to higher-half.
/// Clears L3 entry 0 which points to l2_identity_table (the entire lower-half).
/// Improves security by preventing kernel access via low addresses.
pub fn removeIdentityMapping() void {
    root_table.entries[0] = Pte.INVALID;
    Tlb.flushAll();
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

test "Pte size and layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Pte));
    try std.testing.expectEqual(@as(usize, 64), @bitSizeOf(Pte));
}

test "Pte.INVALID is all zeros" {
    const invalid: u64 = @bitCast(Pte.INVALID);
    try std.testing.expectEqual(@as(u64, 0), invalid);
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
    try std.testing.expect(pte.r);
    try std.testing.expect(pte.u);
    try std.testing.expect(!pte.g);
}

test "VirtAddr.parse extracts correct indices" {
    // Low address: 0x80200000 = 2GB + 2MB
    const va = VirtAddr.parse(0x80200000);
    try std.testing.expectEqual(@as(u9, 0), va.vpn3);
    try std.testing.expectEqual(@as(u9, 2), va.vpn2);
    try std.testing.expectEqual(@as(u9, 1), va.vpn1);
    try std.testing.expectEqual(@as(u9, 0), va.vpn0);
    try std.testing.expectEqual(@as(u12, 0), va.offset);

    // Kernel address
    const kva = VirtAddr.parse(KERNEL_VIRT_BASE + 0x80200000);
    try std.testing.expectEqual(@as(u9, 256), kva.vpn3); // KERNEL_VPN3
    try std.testing.expectEqual(@as(u9, 2), kva.vpn2);
    try std.testing.expectEqual(@as(u9, 1), kva.vpn1);
    try std.testing.expectEqual(@as(u9, 0), kva.vpn0);
}

test "VirtAddr.isCanonical validates addresses" {
    // Sv48: canonical if bits 63:47 are all same as bit 47
    // Lower canonical: 0 to 0x7FFF_FFFF_FFFF (128TB - 1)
    try std.testing.expect(VirtAddr.isCanonical(0x0));
    try std.testing.expect(VirtAddr.isCanonical(0x7FFF_FFFF_FFFF)); // Max lower canonical

    // Upper canonical: 0xFFFF_8000_0000_0000 to max
    try std.testing.expect(VirtAddr.isCanonical(KERNEL_VIRT_BASE));
    try std.testing.expect(VirtAddr.isCanonical(0xFFFF_FFFF_FFFF_FFFF));

    // Non-canonical (hole)
    try std.testing.expect(!VirtAddr.isCanonical(0x8000_0000_0000)); // Just above lower
    try std.testing.expect(!VirtAddr.isCanonical(0xFFFF_7FFF_FFFF_FFFF)); // Just below upper
}

test "Satp.sv48 creates correct value" {
    const satp = Satp.sv48(0x80000000, 5);
    try std.testing.expectEqual(@as(u4, Satp.MODE_SV48), satp.mode);
    try std.testing.expectEqual(@as(u16, 5), satp.asid);
    try std.testing.expectEqual(@as(u44, 0x80000), satp.ppn);
}

test "PageTable size matches page size" {
    try std.testing.expectEqual(PAGE_SIZE, @sizeOf(PageTable));
}

test "translate handles terapage mappings" {
    // Sv48: terapage at L3 (512GB, like ARM64 block at root)
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelLeaf(0x8000000000, true, true); // 512GB terapage at vpn3=1

    // Address with vpn3=1 maps through terapage
    const pa = translate(&root, 0x8000123456);
    try std.testing.expectEqual(@as(?usize, 0x8000123456), pa);

    // Unmapped L3 entry
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x10000000000)); // vpn3=2
}

test "translate returns null for non-canonical addresses" {
    var root = PageTable.EMPTY;
    // Non-canonical address (in Sv48 hole)
    try std.testing.expectEqual(@as(?usize, null), translate(&root, 0x8000_0000_0000));
}

test "mapPage returns NotAligned for misaligned addresses" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1001, 0x2000, .{}));
    try std.testing.expectError(MapError.NotAligned, mapPage(&root, 0x1000, 0x2001, .{}));
}

test "mapPage returns NotCanonical for non-canonical addresses" {
    var root = PageTable.EMPTY;
    // Sv48 non-canonical (in hole)
    try std.testing.expectError(MapError.NotCanonical, mapPage(&root, 0x8000_0000_0000, 0x1000, .{}));
}

test "mapPage returns SuperpageConflict for terapage mappings" {
    // Sv48: terapage at L3 (512GB)
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelLeaf(0x8000000000, true, true); // 512GB terapage at vpn3=1

    // Try to map 4KB page within the terapage
    try std.testing.expectError(MapError.SuperpageConflict, mapPage(&root, 0x8000001000, 0x9000001000, .{}));
}

test "mapPage returns TableNotPresent without intermediate tables" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(MapError.TableNotPresent, mapPage(&root, 0x80001000, 0x90001000, .{}));
}

test "walk returns null for unmapped address" {
    var root = PageTable.EMPTY;
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x80001000));
}

test "walk returns null for terapage mapping" {
    // Sv48: terapage at L3 (not walkable to L0)
    var root = PageTable.EMPTY;
    root.entries[1] = Pte.kernelLeaf(0x8000000000, true, true); // 512GB terapage at vpn3=1

    // Walk stops at terapage, returns null (no L0 entry)
    try std.testing.expectEqual(@as(?*Pte, null), walk(&root, 0x8000001000));
}

test "physToVirt adds KERNEL_VIRT_BASE" {
    const virt = physToVirt(0x80200000);
    try std.testing.expectEqual(@as(usize, KERNEL_VIRT_BASE + 0x80200000), virt);
}

test "virtToPhys subtracts KERNEL_VIRT_BASE" {
    const phys = virtToPhys(KERNEL_VIRT_BASE + 0x80200000);
    try std.testing.expectEqual(@as(usize, 0x80200000), phys);
}

test "physToVirt and virtToPhys are inverses" {
    const original: usize = 0x80200000;
    const round_trip = virtToPhys(physToVirt(original));
    try std.testing.expectEqual(original, round_trip);
}

test "unmapPage returns NotMapped for unmapped address" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(UnmapError.NotMapped, unmapPage(&root, 0x80001000));
}

test "unmapPage returns NotCanonical for non-canonical addresses" {
    var root = PageTable.EMPTY;
    try std.testing.expectError(UnmapError.NotCanonical, unmapPage(&root, 0x8000_0000_0000));
}
