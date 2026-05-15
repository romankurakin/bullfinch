//! ARM64 boot entry point.
//!
//! QEMU drops us into EL1 with the DTB pointer in x0 and no MMU. The boot stub
//! does the bare minimum: save x0 somewhere safe, zero BSS, call
//! `rust_arm64_phys_init` while we are still running with physical addresses,
//! then switch SP and PC into the higher-half mapping and jump to
//! `rust_arm64_main`. Any secondary core that wakes up parks in WFI.
//!
//! See ARM Architecture Reference Manual, D1.2 (Reset and boot).

use core::arch::naked_asm;

#[unsafe(no_mangle)]
pub extern "C" fn rust_arm64_phys_init(dtb_ptr: usize) {
    crate::startup::init::phys_init(kernel::boot::DeviceTreeBlobPhysicalAddress::new(dtb_ptr));
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
        mrs x1, mpidr_el1
        and x1, x1, #0xff
        cbnz x1, 2f

        adrp x0, __stack_top
        add x0, x0, :lo12:__stack_top
        mov sp, x0

        mov x0, #0
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
        "
    );
}
