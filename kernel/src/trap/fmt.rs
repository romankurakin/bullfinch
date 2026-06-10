//! Trap formatting utilities.
//!
//! Panic and trap paths cannot allocate or take locks. These helpers format
//! numbers into fixed-size stack buffers so that output is always possible
//! even when the kernel is in distress.

const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";
const HEX_USIZE_DIGITS: usize = core::mem::size_of::<usize>() * 2;
const DECIMAL_USIZE_DIGITS: usize = 20;

/// Fixed-size buffer holding a decimal-formatted number.
pub struct Decimal {
    buf: [u8; DECIMAL_USIZE_DIGITS],
    len: usize,
}

impl Decimal {
    pub const fn as_bytes(&self) -> &[u8] {
        self.buf.split_at(self.len).0
    }

    pub const fn len(&self) -> usize {
        self.len
    }

    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }
}

pub fn format_hex(value: u64) -> [u8; 16] {
    let mut buf = [0; 16];
    let mut shift: u32 = 60;
    let mut index = 0;

    while index < buf.len() {
        let nibble = ((value >> shift) & 0xf) as usize;
        buf[index] = HEX_DIGITS[nibble];
        index += 1;
        shift = shift.saturating_sub(4);
    }

    buf
}

pub fn format_hex_usize(value: usize) -> [u8; HEX_USIZE_DIGITS] {
    let mut buf = [0; HEX_USIZE_DIGITS];
    let mut index = 0;

    while index < buf.len() {
        let shift = (buf.len() - 1 - index) * 4;
        let nibble = (value >> shift) & 0xf;
        buf[index] = HEX_DIGITS[nibble];
        index += 1;
    }

    buf
}

pub fn format_decimal(value: usize) -> Decimal {
    let mut scratch = [0; DECIMAL_USIZE_DIGITS];
    let mut result = [0; DECIMAL_USIZE_DIGITS];
    let mut value = value;
    let mut index = scratch.len();

    if value == 0 {
        result[0] = b'0';
        return Decimal {
            buf: result,
            len: 1,
        };
    }

    while value > 0 {
        index -= 1;
        scratch[index] = b'0' + (value % 10) as u8;
        value /= 10;
    }

    let len = scratch.len() - index;
    result[..len].copy_from_slice(&scratch[index..]);

    Decimal { buf: result, len }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_hex_output() {
        assert_eq!(&format_hex(0), b"0000000000000000");
        assert_eq!(&format_hex(0xf), b"000000000000000f");
        assert_eq!(&format_hex(0xdead_beef), b"00000000deadbeef");
        assert_eq!(&format_hex(u64::MAX), b"ffffffffffffffff");
    }

    #[test]
    fn formats_usize_hex_output() {
        assert_eq!(format_hex_usize(0)[0], b'0');
        assert_eq!(format_hex_usize(0)[HEX_USIZE_DIGITS - 1], b'0');
        assert_eq!(format_hex_usize(0xf)[HEX_USIZE_DIGITS - 1], b'f');
    }

    #[test]
    fn formats_decimal_output() {
        assert_eq!(format_decimal(0).as_bytes(), b"0");
        assert_eq!(format_decimal(42).as_bytes(), b"42");
        assert_eq!(format_decimal(1_234_567_890).as_bytes(), b"1234567890");
    }
}
