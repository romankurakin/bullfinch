//! Borrowed Device Tree view.
//!
//! The `fdt` crate provides the parser. This module fixes the parser mode so
//! kernel code sees one local DTB type.

pub use ::fdt::FdtError;
use ::fdt::parsing::{Panic, unaligned::UnalignedParser};

pub type Parser<'a> = (UnalignedParser<'a>, Panic);
pub type Fdt<'a> = ::fdt::Fdt<'a, Parser<'a>>;
pub type Node<'a> = ::fdt::nodes::Node<'a, Parser<'a>>;

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
        let dtb = Fdt::new_unaligned(MINIMAL_DTB).unwrap();
        assert_eq!(dtb.header().boot_cpuid, 7);
    }

    #[test]
    fn rejects_invalid_dtb() {
        assert!(Fdt::new_unaligned(&MINIMAL_DTB[..8]).is_err());
    }
}
