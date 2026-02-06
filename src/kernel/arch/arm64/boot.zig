//! ARM64 Boot Entry Point.
//!
//! Bootloader jumps here at EL1 with DTB pointer in x0 (ARM64 boot protocol).
//!
//! Boot sequence:
//! 1. Save DTB pointer, set stack, disable FP/SIMD, zero BSS
//! 2. Call physInit() to init hardware, MMU, traps (returns to us)
//! 3. Switch SP to higher-half, jump to kmain at higher-half address
//!
//! The kernel is linked at higher-half VMA but loaded at physical LMA.
//! PC-relative addressing (adrp+add) works at any base.
//!
//! FP/SIMD is disabled via CPACR_EL1.FPEN=0b00 to enforce no-FP-in-kernel policy.
//! Any kernel FP instruction traps with EC=0x07 (simd_fp access). FP is also
//! disabled at compile time via build.zig (removes neon/fp_armv8 features).

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

        // Disable FP/SIMD access (CPACR_EL1.FPEN = 0b00).
        // FPEN[21:20]: 00=trap all, 01=trap EL0 only, 10/11=no trap.
        // Any FP/SIMD instruction traps with EC=0x07 (simd_fp access).
        // User FP is enabled by setting FPEN=0b11 before returning to EL0.
        // See ARM Architecture Reference Manual, D13.2.29 (CPACR_EL1).
        \\ mov x0, #0
        \\ msr cpacr_el1, x0
        \\ isb

        // Enable PAN (Privileged Access Never). Kernel faults if it
        // accidentally accesses user memory without explicit override.
        // Catches bugs where kernel dereferences user pointers directly.
        // TODO(arm64): Gate PAN write on FEAT_PAN/ID_AA64MMFR1_EL1.PAN.
        \\ msr pan, #1

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
