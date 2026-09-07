//! Flattened Device Tree cell parsing.
//!
//! A cell is a 32-bit value stored with its most significant byte first.
//! DTB numeric properties use one or more cells. This module reads scalar
//! values that Bullfinch needs in addition to the parser's structured helpers.

use core::convert::TryInto;

/// Reads a 1-cell or 2-cell big-endian integer.
///
/// With two cells, the first contains the high 32 bits. Trailing bytes are
/// ignored. Returns `None` for other cell counts or an input that is too short.
pub fn read_cells(data: &[u8], cells: u8) -> Option<u64> {
    match cells {
        1 => {
            let bytes: [u8; 4] = data.get(..4)?.try_into().ok()?;
            Some(u64::from(u32::from_be_bytes(bytes)))
        }
        2 => {
            let bytes: [u8; 8] = data.get(..8)?.try_into().ok()?;
            Some(u64::from_be_bytes(bytes))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_big_endian_cells() {
        assert_eq!(read_cells(&[0x12, 0x34, 0x56, 0x78], 1), Some(0x1234_5678));
        assert_eq!(
            read_cells(&[0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00], 2),
            Some(0x8000_0000)
        );
        assert_eq!(
            read_cells(&[0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0], 2),
            Some(0x1234_5678_9abc_def0)
        );
        assert_eq!(read_cells(&[0; 4], 0), None);
        assert_eq!(read_cells(&[0; 4], 3), None);
        assert_eq!(read_cells(&[0; 3], 1), None);
    }
}
