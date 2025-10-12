/* Linker script for RISC-V kernel on QEMU 'virt' machine.
   Defines memory layout, entry point, and symbols used by boot code.
   Ensures proper alignment and zeroing of BSS; stack above kernel sections. */

STACK_SIZE = 16 * 1024; /* 16KB kernel stack - sufficient for early boot without heap */

ENTRY(_start) /* Entry point defined in boot.zig - must be first in .text */

SECTIONS {
    /* Kernel load address: 0x80200000 (2MB into DRAM on QEMU virt).
       Above OpenSBI (0x80000000) to avoid conflicts; matches QEMU default. */
    . = 0x80200000;

    .text : {
        KEEP(*(.text.boot)) /* Preserve boot code at image start for firmware */
        *(.text*) /* All executable code */
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
