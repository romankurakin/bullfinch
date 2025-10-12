//! Boot shim that clears BSS and transfers control to main.
//! Runs in early boot with no stack or memory management. Must initialize stack and zero BSS
//! to prevent undefined global state. Failure risks kernel corruption.
//! RISC-V: OpenSBI leaves us in M-mode with undefined stack. Naked function avoids Zig prologue.

// Linker-defined symbols marking BSS boundaries. Must zero before main() per C ABI.
extern const __bss_start: u8;
extern const __bss_end: u8;

// Architecture-independent kernel entry point.
extern fn main() callconv(.c) void;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    // Set stack pointer to linker-defined __stack_top to avoid corrupting code/data.
    // Critical for safety: early operations must not overwrite kernel sections.
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
