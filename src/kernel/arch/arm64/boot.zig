//! ARM64 Boot Entry Point.
//!
//! This is the first code that runs when the kernel loads. The bootloader places us
//! at a physical address but we're linked at a higher-half virtual address. Since
//! MMU is off, we use PC-relative addressing (adrp+add) which works at any address.
//!
//! Boot sequence: set stack pointer, enable FP/SIMD, zero BSS, call main().
//!
//! We must enable FP/SIMD via CPACR_EL1.FPEN because Zig's compiler may emit SIMD
//! instructions for array operations. Without this, any FP/SIMD instruction traps.

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
