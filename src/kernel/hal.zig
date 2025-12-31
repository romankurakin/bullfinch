//! Unified Hardware Abstraction Layer.
//! Combines architecture-specific and board-specific operations into a single interface.
//! Kernel code imports only this module for all hardware operations.

const arch = @import("arch");
const board = @import("board");

// Re-export boot for entry point inclusion
pub const boot = arch.boot;

// Re-export trap for test helpers (testTriggerBreakpoint, etc.)
pub const trap = arch.trap;

// Re-export mmu for direct access when needed
pub const mmu = arch.mmu;

// Re-export board config for memory layout constants
pub const config = board.config;

// ============================================================================
// Board-specific operations (UART, peripherals)
// ============================================================================

/// Initialize board hardware (UART, peripherals).
pub fn init() void {
    board.hal.init();
}

/// Print string to console.
pub fn print(s: []const u8) void {
    board.hal.print(s);
}

/// Switch MMIO peripherals to higher-half virtual addresses.
/// Call before removeIdentityMapping() to keep peripherals working.
/// HAL composes board config + arch address translation.
pub fn useHigherHalfAddresses() void {
    if (@hasDecl(board.config, "UART_PHYS")) {
        board.hal.setUartBase(arch.hal.physToVirt(board.config.UART_PHYS));
    }
}

// ============================================================================
// Architecture-specific operations (MMU, trap, CPU)
// ============================================================================

/// Initialize MMU with identity + higher-half mapping, enable paging.
pub fn initMmu() void {
    arch.hal.initMmu();
}

/// Initialize trap/exception handling.
/// Injects board's print function into trap handler to break circular dependency.
pub fn initTrap() void {
    arch.hal.initTrap(board.hal.print);
}

/// Halt the CPU (disable interrupts and wait forever).
pub fn halt() noreturn {
    arch.hal.halt();
}

/// Transition to running in higher-half address space.
pub fn jumpToHigherHalf(continuation: *const fn (usize) noreturn, arg: usize) noreturn {
    arch.hal.jumpToHigherHalf(continuation, arg);
}

/// Remove identity mapping after transitioning to higher-half.
pub fn removeIdentityMapping() void {
    arch.hal.removeIdentityMapping();
}

/// Flush all TLB entries.
pub fn flushTlb() void {
    arch.hal.flushTlb();
}

/// Flush TLB for a specific virtual address.
pub fn flushTlbAddr(vaddr: usize) void {
    arch.hal.flushTlbAddr(vaddr);
}

/// Get kernel virtual base address.
pub fn kernelVirtBase() usize {
    return arch.hal.kernelVirtBase();
}

/// Convert physical address to kernel virtual address.
pub fn physToVirt(paddr: usize) usize {
    return arch.hal.physToVirt(paddr);
}

/// Convert kernel virtual address to physical address.
pub fn virtToPhys(vaddr: usize) usize {
    return arch.hal.virtToPhys(vaddr);
}
