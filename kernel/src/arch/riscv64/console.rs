//! RISC-V console output.
//!
//! Uses OpenSBI's legacy console call during early boot. That keeps UART device
//! ownership in firmware before driver setup.

pub struct Console;

impl Console {
    pub const fn new() -> Self {
        Self
    }

    pub fn put_byte(&mut self, byte: u8) {
        sbi_putchar(byte);
    }
}

pub fn post_mmu_init() {}

fn sbi_putchar(byte: u8) {
    // SAFETY: OpenSBI starts the kernel in S-mode and supports the legacy
    // console putchar call on QEMU virt during this early MVP boot path.
    unsafe {
        core::arch::asm!(
            "ecall",
            in("a0") byte as usize,
            in("a6") 0usize,
            in("a7") 0x01usize,
            lateout("a0") _,
            lateout("a1") _,
            options(nostack)
        );
    }
}
