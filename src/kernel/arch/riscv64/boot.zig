//! RISC-V Boot Entry Point.
//!
//! OpenSBI loads and jumps to us in S-mode with hart ID in a0 and DTB pointer in a1.
//! Boot sequence:
//!   1. Save DTB pointer, set stack, zero BSS
//!   2. Call physInit() to init hardware, MMU, traps (returns to us)
//!   3. Switch SP to higher-half, jump to kmain at higher-half address
//!
//! The kernel is linked at higher-half VMA but loaded at physical LMA.
//! PC-relative addressing (la pseudo-instruction) works at any base.

extern const __bss_start: u8;
extern const __bss_end: u8;
extern const KERNEL_VIRT_BASE: usize;
extern fn physInit() void;
extern fn kmain() noreturn;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        // Save DTB pointer (passed in a1 by OpenSBI) to callee-saved register
        \\ mv s0, a1

        // Set up stack and zero BSS
        \\ la sp, __stack_top
        \\ la t0, __bss_start
        \\ la t1, __bss_end
        \\ clear_bss:
        \\   sd zero, 0(t0)
        \\   addi t0, t0, 8
        \\   blt t0, t1, clear_bss

        // Save DTB pointer to global before physInit (which may use console)
        \\ la t0, dtb_ptr
        \\ sd s0, 0(t0)

        // Initialize hardware, MMU, traps (all at physical addresses)
        \\ call physInit

        // Switch to higher-half: add KERNEL_VIRT_BASE to SP, jump to kmain
        \\ la t0, KERNEL_VIRT_BASE
        \\ ld t0, 0(t0)
        \\ add sp, sp, t0
        \\ la t1, kmain
        \\ add t1, t1, t0
        \\ jr t1

        \\ hang:
        \\   wfi
        \\   j hang
    );
}

/// DTB pointer saved during boot, before physInit.
pub export var dtb_ptr: usize = 0;
