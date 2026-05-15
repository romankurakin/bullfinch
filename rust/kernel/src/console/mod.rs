//! Portable console output.
//!
//! Most serial terminals expect `\r\n` for a newline, but Rust strings use
//! `\n` alone. This module adds the missing `\r` and bridges the architecture
//! UART driver to `fmt::Write` so that `write!` and `writeln!` work.

use core::fmt;

/// Not `Sync`. Concurrent access must be serialized by the caller.
pub struct Console {
    device: crate::arch::console::Console,
}

impl Console {
    pub const fn new() -> Self {
        Self {
            device: crate::arch::console::Console::new(),
        }
    }

    /// Send one byte, inserting `\r` before `\n` for serial terminals.
    pub fn put_byte(&mut self, byte: u8) {
        if byte == b'\n' {
            self.device.put_byte(b'\r');
        }
        self.device.put_byte(byte);
    }

    pub fn print(&mut self, text: &str) {
        for byte in text.bytes() {
            self.put_byte(byte);
        }
    }

    pub fn print_hex_usize(&mut self, value: usize) {
        self.print("0x");
        for byte in kernel::trap::fmt::format_hex_usize(value) {
            self.put_byte(byte);
        }
    }

    pub fn print_dec_usize(&mut self, value: usize) {
        for byte in kernel::trap::fmt::format_decimal(value).as_bytes() {
            self.put_byte(*byte);
        }
    }
}

impl fmt::Write for Console {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        self.print(text);
        Ok(())
    }
}

/// Print without a named binding. Not re-entrant.
pub fn print_unsafe(text: &str) {
    Console::new().print(text);
}

/// Notify the arch console driver that the higher-half mapping is live.
pub fn post_mmu_init() {
    crate::arch::console::post_mmu_init();
}
