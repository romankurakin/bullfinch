//! RISC-V boot shim - clears BSS and transfers to main().
//! OpenSBI leaves us in S-mode. Must set SP and zero BSS before main().

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
