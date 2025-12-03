//! ARM64 boot shim - clears BSS and transfers to main().
//! Runs without stack or memory management. Must set SP and zero BSS before main().

extern const __bss_start: u8;
extern const __bss_end: u8;
extern fn main() callconv(.c) void;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ ldr x0, =__stack_top
        \\ mov sp, x0
        \\ ldr x0, =__bss_start
        \\ ldr x1, =__bss_end
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
