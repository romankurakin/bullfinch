//! ARM64 Boot Entry Point.
//!
//! Bootloader jumps here at EL1 with DTB pointer in x0 (ARM64 boot protocol).
//!
//! Boot sequence:
//! 1. Save DTB pointer, set stack, enable FP/SIMD, zero BSS
//! 2. Call physInit() to init hardware, MMU, traps (returns to us)
//! 3. Switch SP to higher-half, jump to kmain at higher-half address
//!
//! The kernel is linked at higher-half VMA but loaded at physical LMA.
//! PC-relative addressing (adrp+add) works at any base.
//!
//! We must enable FP/SIMD via CPACR_EL1.FPEN because Zig's compiler may emit SIMD
//! instructions for array operations. Without this, any FP/SIMD instruction traps.

extern const __bss_start: u8;
extern const __bss_end: u8;
extern const KERNEL_VIRT_BASE: usize;
extern fn physInit() void;
extern fn kmain() noreturn;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        // Bootloader passes DTB pointer in x0 (ARM64 boot protocol).
        // Save it to callee-saved register before we clobber x0.
        \\ mov x19, x0

        // Set up stack pointer (PC-relative addressing for position independence)
        \\ adrp x0, __stack_top
        \\ add x0, x0, :lo12:__stack_top
        \\ mov sp, x0

        // Enable FP/SIMD access (CPACR_EL1.FPEN = 0b11).
        // Without this, any FP/SIMD instruction traps with EC=0x07.
        // Zig compiler may emit SIMD for array operations.
        \\ mov x0, #(3 << 20)
        \\ msr cpacr_el1, x0
        \\ isb

        // Clear BSS section (PC-relative addressing)
        \\ adrp x0, __bss_start
        \\ add x0, x0, :lo12:__bss_start
        \\ adrp x1, __bss_end
        \\ add x1, x1, :lo12:__bss_end
        \\ clear_bss:
        \\   str xzr, [x0]
        \\   add x0, x0, #8
        \\   cmp x0, x1
        \\   b.lt clear_bss

        // Save DTB pointer to global before physInit (which may use console)
        \\ adrp x0, dtb_ptr
        \\ add x0, x0, :lo12:dtb_ptr
        \\ str x19, [x0]

        // Initialize hardware, MMU, traps (all at physical addresses)
        \\ bl physInit

        // Switch to higher-half: add KERNEL_VIRT_BASE to SP, jump to kmain
        \\ adrp x0, KERNEL_VIRT_BASE
        \\ add x0, x0, :lo12:KERNEL_VIRT_BASE
        \\ ldr x0, [x0]
        \\ add sp, sp, x0
        \\ adrp x1, kmain
        \\ add x1, x1, :lo12:kmain
        \\ add x1, x1, x0
        \\ br x1
        \\ hang:
        \\   wfi
        \\   b hang
    );
}

/// DTB pointer saved during boot, before physInit.
pub export var dtb_ptr: usize = 0;
