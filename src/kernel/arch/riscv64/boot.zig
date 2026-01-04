//! RISC-V Boot Entry Point.
//!
//! OpenSBI loads and jumps to us in S-mode. Unlike ARM, we don't need to enable FP
//! since RISC-V F extension is always accessible. Boot sequence: set stack, zero BSS,
//! call main(). The kernel is linked at higher-half VMA but loaded at physical LMA;
//! the la pseudo-instruction generates PC-relative addressing that works at any base.

extern const __bss_start: u8;
extern const __bss_end: u8;
extern fn main() callconv(.c) void;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ la sp, __stack_top
        \\ la t0, __bss_start
        \\ la t1, __bss_end
        \\ clear_bss:
        \\   sd zero, 0(t0)
        \\   addi t0, t0, 8
        \\   blt t0, t1, clear_bss
        \\ call main
        \\ hang:
        \\   wfi
        \\   j hang
    );
}
