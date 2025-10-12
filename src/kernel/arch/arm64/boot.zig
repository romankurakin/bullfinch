//! Boot shim that clears BSS and transfers control to main.
//! Runs in early boot with no stack or memory management. Must initialize stack and zero BSS
//! to prevent undefined global state. Failure risks kernel corruption.
//! ARM64: Reset vector has no paging/stack. Naked function avoids Zig prologue.

// Linker-defined symbols marking BSS boundaries. Must zero before main() per C ABI.
extern const __bss_start: u8;
extern const __bss_end: u8;

// Architecture-independent kernel entry point.
extern fn main() callconv(.c) void;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    // Set stack pointer to linker-defined __stack_top to avoid corrupting code/data.
    // Critical for safety: early operations must not overwrite kernel sections.
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
