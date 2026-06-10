//! ARM64 console output.
//!
//! QEMU virt exposes a PL011 UART at a fixed physical address. This is TX-only
//! for boot diagnostics. The real driver model comes later.

use core::sync::atomic::{AtomicUsize, Ordering};

use kernel::mmu::PhysicalAddress;

const UART0_PHYSICAL_BASE: usize = 0x0900_0000;
const UART_FR_TXFF: u32 = 1 << 5;

static UART_BASE: AtomicUsize = AtomicUsize::new(UART0_PHYSICAL_BASE);

pub struct Console;

impl Console {
    pub const fn new() -> Self {
        Self
    }

    pub fn put_byte(&mut self, byte: u8) {
        while uart_tx_full() {
            core::hint::spin_loop();
        }

        let data = UART_BASE.load(Ordering::Relaxed) as *mut u8;
        // SAFETY: QEMU virt exposes PL011 UART0 at 0x0900_0000. UART_DR is the
        // byte-wide transmit register, and volatile preserves the MMIO write.
        unsafe { core::ptr::write_volatile(data, byte) };
    }
}

pub fn post_mmu_init() {
    UART_BASE.store(
        super::mmu::physical_to_virtual(PhysicalAddress::new(UART0_PHYSICAL_BASE)).get(),
        Ordering::Relaxed,
    );
}

fn uart_tx_full() -> bool {
    let flags = (UART_BASE.load(Ordering::Relaxed) + 0x18) as *const u32;
    // SAFETY: QEMU virt exposes PL011 UART0 at 0x0900_0000. UART_FR is the
    // aligned 32-bit flag register, and volatile preserves the MMIO read.
    unsafe { core::ptr::read_volatile(flags) & UART_FR_TXFF != 0 }
}
