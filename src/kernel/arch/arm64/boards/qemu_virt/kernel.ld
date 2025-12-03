/* Linker script for ARM64 kernel on QEMU 'virt' machine.
   Defines memory layout, entry point, and symbols used by boot code.
   Ensures proper alignment and zeroing of BSS; stack above kernel sections. */

STACK_SIZE = 16 * 1024; /* 16KB kernel stack - sufficient for early boot without heap */

ENTRY(_start) /* Entry point defined in boot.zig - must be first in .text */

SECTIONS {
    /* Kernel load address: 0x40080000 (8MB into DRAM on QEMU virt).
       Standard location for ARM64 kernels; avoids firmware conflicts. */
    . = 0x40080000;

    .text : {
        KEEP(*(.text.boot)) /* Preserve boot code at image start for reset vector */
        *(.text*) /* All executable code */
    }

    /* Exception vector table - ARM64 VBAR_EL1 requires 2KB alignment.
       Table is 0x800 bytes (16 entries × 128 bytes each).
       Extracted to separate section for clarity and alignment requirements. */
    .vectors : ALIGN(2048) {
        __vectors_start = .;
        KEEP(*(.vectors))
        __vectors_end = .;
    }

    .rodata : {
        *(.rodata*) /* Read-only data (constants, strings) */
    }

    .data : {
        *(.data*) /* Initialized writable data */
    }

    /* BSS: Uninitialized data, zeroed by boot code.
       Symbols __bss_start/__bss_end used in boot.zig for memset. */
    .bss : {
        __bss_start = .;
        *(.bss*)
        . = ALIGN(16); /* Align for potential SIMD/vector ops */
        __bss_end = .;
    }

    . = ALIGN(16); /* Align stack base */
    __stack_bottom = .; /* Stack grows down from __stack_top */
    . = . + STACK_SIZE;
    __stack_top = .; /* Initial SP set here in boot.zig */
}