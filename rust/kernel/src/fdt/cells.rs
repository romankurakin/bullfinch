//! Flattened Device Tree cell parsing.
//!
//! DTB numeric properties are big-endian arrays of 32-bit cells. The `fdt`
//! parser iterates structured `reg` values; this module reads scalar values.

use core::convert::TryInto;

/// Reads a 1-cell or 2-cell big-endian integer.
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
