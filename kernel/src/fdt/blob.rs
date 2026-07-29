//! Borrowed Device Tree view.
//!
//! `dtoolkit` provides the parser. This module keeps parser-specific type
//! names behind one local DTB API.

pub use dtoolkit::fdt::{Fdt, FdtNode as Node};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FdtError {
    MalformedBlob,
    MalformedProperty,
    InvalidStandardData,
}

impl From<dtoolkit::error::FdtParseError> for FdtError {
    fn from(_: dtoolkit::error::FdtParseError) -> Self {
        Self::MalformedBlob
    }
}

impl From<dtoolkit::error::PropertyError> for FdtError {
    fn from(_: dtoolkit::error::PropertyError) -> Self {
        Self::MalformedProperty
    }
}

impl From<dtoolkit::error::StandardError> for FdtError {
    fn from(_: dtoolkit::error::StandardError) -> Self {
        Self::InvalidStandardData
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL_DTB: &[u8] = &[
        0xd0, 0x0d, 0xfe, 0xed, // magic
        0x00, 0x00, 0x00, 0x48, // totalsize = 72
        0x00, 0x00, 0x00, 0x38, // off_dt_struct = 56
        0x00, 0x00, 0x00, 0x48, // off_dt_strings = 72
        0x00, 0x00, 0x00, 0x28, // off_mem_rsvmap = 40
        0x00, 0x00, 0x00, 0x11, // version = 17
        0x00, 0x00, 0x00, 0x10, // last_comp_version = 16
        0x00, 0x00, 0x00, 0x07, // boot_cpuid_phys = 7
        0x00, 0x00, 0x00, 0x00, // size_dt_strings = 0
        0x00, 0x00, 0x00, 0x10, // size_dt_struct = 16
        0x00, 0x00, 0x00, 0x00, // memory reservation
        0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x01, // FDT_BEGIN_NODE
        0x00, 0x00, 0x00, 0x00, // root name ""
        0x00, 0x00, 0x00, 0x02, // FDT_END_NODE
        0x00, 0x00, 0x00, 0x09, // FDT_END
    ];

    #[test]
    fn parses_minimal_dtb() {
        let dtb = Fdt::new(MINIMAL_DTB).unwrap();
        assert_eq!(dtb.boot_cpuid_phys(), 7);
    }

    #[test]
    fn rejects_invalid_dtb() {
        assert!(Fdt::new(&MINIMAL_DTB[..8]).is_err());
    }
}
