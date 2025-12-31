//! ARM64 boot shim - clears BSS and transfers to main().
//! Runs without stack or memory management. Must set SP, enable FP/SIMD, and zero BSS before main().
//!
//! Boot code uses PC-relative addressing (adrp+add) because kernel is linked at
//! higher-half VMA but loaded at physical LMA. The MMU isn't enabled yet, so we
//! must use PC-relative offsets which work at any base address.

extern const __bss_start: u8;
extern const __bss_end: u8;
extern fn main() callconv(.c) void;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
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

        \\ bl main

        \\ hang:
        \\   wfi
        \\   b hang
    );
}
