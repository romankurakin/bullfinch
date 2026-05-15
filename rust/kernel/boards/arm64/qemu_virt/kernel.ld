/* Linker script for the ARM64 kernel on QEMU virt.
   The kernel links at a higher-half virtual address and loads at its physical
   boot address. Boot code stays position independent until the MMU is enabled. */

STACK_SIZE = 32 * 1024;

__dram_base = 0x40000000;
__kernel_phys_load = 0x40080000;
__kernel_virt_load = 0xFFFFFF8040080000;

ENTRY(_start)

SECTIONS {
    . = __kernel_virt_load;

    .text : AT(__kernel_phys_load) {
        KEEP(*(.text.boot))
        *(.text*)
    }

    /* VBAR_EL1 requires the vector table to be 2 KiB aligned. */
    .vectors : ALIGN(2048) {
        __vectors_start = .;
        KEEP(*(.vectors))
        __vectors_end = .;
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data*)
    }

    .bss : {
        __bss_start = .;
        *(.bss*)
        . = ALIGN(16);
        __bss_end = .;
    }

    . = ALIGN(16);
    __stack_bottom = .;
    . = . + STACK_SIZE;
    __stack_top = .;

    . = ALIGN(4096);
    __kernel_end = .;
}
