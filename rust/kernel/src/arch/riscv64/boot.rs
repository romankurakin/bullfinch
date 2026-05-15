//! RISC-V boot entry point.
//!
//! OpenSBI drops us into S-mode with the boot hart in a0 and the DTB pointer
//! in a1. The boot stub sets gp, claims exactly one hart atomically so that
//! any loser parks in WFI, zeros BSS, calls `rust_riscv64_phys_init` while
//! we are still running with physical addresses, then switches SP and PC into
//! the higher-half mapping and jumps to `rust_riscv64_main`.
//!
//! See RISC-V Privileged Specification, Chapter 3 (Machine-Level ISA).

use core::arch::naked_asm;

#[unsafe(no_mangle)]
pub extern "C" fn rust_riscv64_phys_init(dtb_ptr: usize) {
    crate::startup::init::phys_init(kernel::boot::DeviceTreeBlobPhysicalAddress::new(dtb_ptr));
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_riscv64_main(boot_hart: usize, dtb_ptr: usize) -> ! {
    crate::kernel_main(crate::BootInfo {
        boot_hart: Some(kernel::boot::HartId::new(boot_hart)),
        dtb: kernel::boot::DeviceTreeBlobPhysicalAddress::new(dtb_ptr),
    })
}

#[unsafe(naked)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.boot")]
pub unsafe extern "C" fn _start() -> ! {
    naked_asm!(
        "
        .option push
        .option norelax
        la gp, __global_pointer$
        .option pop

        mv s0, a0
        mv s1, a1

        la t0, BOOT_HART_CLAIM
        li t1, 1
        amoadd.d t2, t1, (t0)
        bnez t2, 2f

        la sp, __stack_top

        li t0, (3 << 13)
        csrc sstatus, t0

        la t0, __bss_start
        la t1, __bss_end
    1:
        bgeu t0, t1, 3f
        sd zero, 0(t0)
        addi t0, t0, 8
        j 1b
    3:
        mv a0, s1
        call rust_riscv64_phys_init

        li t0, 0xffff800000000000
        la sp, __stack_top
        add sp, sp, t0
        la t1, rust_riscv64_main
        add t1, t1, t0
        mv a0, s0
        mv a1, s1
        jr t1
    2:
        wfi
        j 2b
        "
    );
}
