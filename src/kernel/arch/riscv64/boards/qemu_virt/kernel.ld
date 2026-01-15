/* Linker script for RISC-V kernel on QEMU 'virt' machine.
   Kernel is linked at higher-half virtual addresses (VMA) but loaded at
   physical addresses (LMA). Boot code is position-independent until MMU
   enables the higher-half mapping. */

STACK_SIZE = 64 * 1024; /* 64KB kernel stack */

/* Memory layout constants */
__dram_base = 0x80000000;             /* DRAM starts here on QEMU virt */
__kernel_phys_load = 0x80200000;      /* Kernel physical load address (above OpenSBI) */
__kernel_virt_load = 0xFFFF800080200000; /* Kernel virtual load address */

ENTRY(_start) /* Entry point defined in boot.zig - must be first in .text */

SECTIONS {
    /* Virtual address for linking - all references use higher-half addresses.
       AT() specifies physical load address for firmware/bootloader. */
    . = __kernel_virt_load;

    /* Boot code must be position-independent as it runs before MMU enable.
       Placed first so firmware loads it at correct physical address. */
    .text : AT(__kernel_phys_load) {
        KEEP(*(.text.boot)) /* Position-independent boot code */
        *(.text*) /* All executable code */
    }

    /* Trap entry point - RISC-V stvec requires 256-byte alignment for Vectored Mode. */
    .trap : ALIGN(256) {
        __trap_start = .;
        KEEP(*(.trap))
        __trap_end = .;
    }

    .rodata : {
        *(.rodata*) /* Read-only data (constants, strings) */
    }

    .data : {
        . = ALIGN(16);
        __global_pointer$ = . + 0x800;
        *(.sdata*)
        *(.data*) /* Initialized writable data */
    }

    /* BSS: Uninitialized data, zeroed by boot code. */
    .bss : {
        . = ALIGN(16);
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        . = ALIGN(16);
        __bss_end = .;
    }

    /* Kernel boot stack. TODO(vm): Add guard page below stack - leave one
       page unmapped so stack overflow faults instead of corrupting memory. */
    . = ALIGN(16);
    __stack_bottom = .;
    . = . + STACK_SIZE;
    __stack_top = .;

    . = ALIGN(4096);
    __kernel_end = .;
}
