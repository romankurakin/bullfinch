//! RISC-V 64-bit architecture module.
//! Re-exports all arch-specific modules for use by board and kernel code.

pub const uart = @import("uart.zig");
pub const mmu = @import("mmu.zig");
pub const sbi = @import("sbi.zig");
pub const trap = @import("trap.zig");
pub const boot = @import("boot.zig");

/// Architecture-level HAL - operations that are arch-specific but board-independent.
pub const hal = struct {
    /// Initialize MMU with identity + higher-half mapping, enable paging.
    pub fn initMmu() void {
        mmu.init();
    }

    /// Flush all TLB entries
    pub fn flushTlb() void {
        mmu.Tlb.flushAll();
    }

    /// Flush TLB for a specific virtual address
    pub fn flushTlbAddr(vaddr: usize) void {
        mmu.Tlb.flushAddr(vaddr);
    }

    /// Get kernel virtual base address
    pub fn kernelVirtBase() usize {
        return mmu.KERNEL_VIRT_BASE;
    }

    /// Convert physical address to kernel virtual address
    pub fn physToVirt(paddr: usize) usize {
        return mmu.physToVirt(paddr);
    }

    /// Convert kernel virtual address to physical address
    pub fn virtToPhys(vaddr: usize) usize {
        return mmu.virtToPhys(vaddr);
    }

    /// Transition to running in higher-half address space
    pub fn jumpToHigherHalf(continuation: *const fn (usize) noreturn, arg: usize) noreturn {
        mmu.jumpToHigherHalf(continuation, arg);
    }

    /// Remove identity mapping after transitioning to higher-half
    pub fn removeIdentityMapping() void {
        mmu.removeIdentityMapping();
    }

    /// Initialize trap/exception handling.
    /// Print function is injected to avoid circular dependencies.
    pub fn initTrap(print_func: *const fn ([]const u8) void) void {
        trap.init(print_func);
    }

    /// Halt the CPU (disable interrupts and wait forever)
    pub fn halt() noreturn {
        trap.halt();
    }
};
