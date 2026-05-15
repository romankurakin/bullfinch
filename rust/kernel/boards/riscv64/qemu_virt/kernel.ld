/* Linker script for the RISC-V kernel on QEMU virt.
   The kernel links at a higher-half virtual address and loads above OpenSBI.
   Boot code stays position independent until the MMU is enabled. */

STACK_SIZE = 32 * 1024;

__dram_base = 0x80000000;
__kernel_phys_load = 0x80200000;
__kernel_virt_load = 0xFFFF800080200000;

ENTRY(_start)

SECTIONS {
    . = __kernel_virt_load;

    .text : AT(__kernel_phys_load) {
        KEEP(*(.text.boot))
        *(.text*)
    }

    /* Vectored stvec mode requires the trap table to be 256-byte aligned. */
    .trap : ALIGN(256) {
        __trap_start = .;
        KEEP(*(.trap))
        __trap_end = .;
    }

    .rodata : {
        *(.rodata*)
    }

    .data : {
        . = ALIGN(16);
        __global_pointer$ = . + 0x800;
        *(.sdata*)
        *(.data*)
    }

    .bss : {
        . = ALIGN(16);
        __bss_start = .;
        *(.sbss*)
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
