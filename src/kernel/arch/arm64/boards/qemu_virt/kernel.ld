/* Linker script for ARM64 kernel on QEMU 'virt' machine.
   Kernel is linked at higher-half virtual addresses (VMA) but loaded at
   physical addresses (LMA). Boot code is position-independent until MMU
   enables the higher-half mapping. */

STACK_SIZE = 16 * 1024; /* 16KB kernel stack - sufficient for early boot without heap */

/* Memory layout constants */
__dram_base = 0x40000000;              /* DRAM starts here on QEMU virt */
__kernel_phys_base = 0x40080000;       /* Kernel load address */
__kernel_virt_base = 0xFFFFFF8040080000; /* Higher-half virtual address */

ENTRY(_start) /* Entry point defined in boot.zig - must be first in .text */

SECTIONS {
    /* Virtual address for linking - all references use higher-half addresses.
       AT() specifies physical load address for firmware/bootloader. */
    . = __kernel_virt_base;

    /* Boot code must be position-independent as it runs before MMU enable.
       Placed first so firmware loads it at correct physical address. */
    .text : AT(__kernel_phys_base) {
        KEEP(*(.text.boot)) /* Position-independent boot code */
        *(.text*) /* All executable code */
    }

    /* Exception vector table - ARM64 VBAR_EL1 requires 2KB alignment. */
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

    /* BSS: Uninitialized data, zeroed by boot code. */
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
