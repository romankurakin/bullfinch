//! ARM64 boot entry point.
//!
//! QEMU enters EL1 with the DTB pointer in x0 and the MMU disabled. The boot
//! stub saves x0 and zeros BSS, the region for zero-initialized static data.
//! It calls `rust_arm64_phys_init` while addresses are still physical.
//! It then switches SP and PC into the higher-half mapping and jumps to
//! `rust_arm64_main`. Any secondary core that wakes up parks in WFI.
//!
//! See ARM Architecture Reference Manual, D1.2 (Reset and boot).

use core::arch::naked_asm;

#[unsafe(no_mangle)]
pub extern "C" fn rust_arm64_phys_init(dtb_ptr: usize) {
    if crate::startup::init::phys_init(kernel::boot::DeviceTreeBlobPhysicalAddress::new(dtb_ptr))
        .is_err()
    {
        crate::console::print_unsafe("\n[PANIC]\nboot: memory map initialization failed\n");
        crate::hal::cpu::halt();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_arm64_main(dtb_ptr: usize) -> ! {
    crate::kernel_main(crate::BootInfo {
        boot_hart: None,
        dtb: kernel::boot::DeviceTreeBlobPhysicalAddress::new(dtb_ptr),
    })
}

#[unsafe(naked)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.boot")]
pub unsafe extern "C" fn _start() -> ! {
    naked_asm!(
        "
        mov x19, x0
        // Admit only the core with affinity 0.0.0.0. Aff0 identifies a core
        // within a cluster, so another cluster can also have a core with Aff0=0.
        // Checking all affinity fields prevents both cores from running boot.
        // The two masks cover Aff2:Aff1:Aff0 in bits [23:0] and Aff3 in bits
        // [39:32], skipping the MT, U, and RES1 bits between them.
        mrs x1, mpidr_el1
        and x2, x1, #0xffffff
        cbnz x2, 2f
        and x2, x1, #0xff00000000
        cbnz x2, 2f

        adrp x0, __stack_top
        add x0, x0, :lo12:__stack_top
        mov sp, x0

        mov x0, #{kernel_cpacr}
        msr cpacr_el1, x0
        isb

        adrp x0, __bss_start
        add x0, x0, :lo12:__bss_start
        adrp x1, __bss_end
        add x1, x1, :lo12:__bss_end
    1:
        cmp x0, x1
        b.hs 3f
        str xzr, [x0], #8
        b 1b
    3:
        mov x0, x19
        bl rust_arm64_phys_init
        adrp x0, __stack_top
        add x0, x0, :lo12:__stack_top
        mov x1, #0
        movk x1, #0xff80, lsl #32
        movk x1, #0xffff, lsl #48
        add sp, x0, x1
        adrp x16, rust_arm64_main
        add x16, x16, :lo12:rust_arm64_main
        add x16, x16, x1
        mov x0, x19
        br x16
    2:
        wfi
        b 2b
        ",
        kernel_cpacr = const super::fp::CPACR_EL1_KERNEL,
    );
}
