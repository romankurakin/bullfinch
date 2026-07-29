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
        __kernel_text_start = .;
        KEEP(*(.text.boot))
        *(.text*)
    }

    /* Match the 256-slot assembly table's requested alignment. */
    .trap ALIGN(1024) : {
        __trap_start = .;
        KEEP(*(.trap))
        __trap_end = .;
    }
    . = ALIGN(4096);
    __kernel_text_end = .;

    .rodata ALIGN(4096) : {
        __kernel_rodata_start = .;
        *(.rodata*)
        *(.eh_frame*)
        . = ALIGN(4096);
        __kernel_rodata_end = .;
    }

    .data ALIGN(4096) : {
        __kernel_data_start = .;
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
    __kernel_data_end = .;
}
