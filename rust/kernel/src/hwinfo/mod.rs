//! Hardware information discovered from the Device Tree.
//!
//! The DTB is firmware data. Boot turns it into a compact snapshot so later
//! subsystems do not repeatedly walk device-tree nodes.

use crate::{
    boot::DeviceTreeBlobPhysicalAddress,
    fdt::{Fdt, Node, cells::read_cells},
    limits::{MAX_MEMORY_ARENAS, MAX_RESERVED_REGIONS},
    mmu::address::PhysicalAddress,
    time::Frequency,
};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MemoryRegion {
    pub base: PhysicalAddress,
    pub size: usize,
}

impl MemoryRegion {
    fn from_fdt_reg(address: u64, size: u64) -> Option<Self> {
        Some(Self {
            base: PhysicalAddress::try_from_u64(address)?,
            size: usize::try_from(size).ok()?,
        })
    }

    pub fn end(self) -> Option<PhysicalAddress> {
        self.base.checked_add(self.size)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Features {
    pub hardware_random: bool,
    pub interrupt_controller: Option<InterruptControllerInfo>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InterruptControllerInfo {
    GicV2 {
        distributor_base: PhysicalAddress,
        cpu_interface_base: Option<PhysicalAddress>,
    },
    GicV3 {
        distributor_base: PhysicalAddress,
        redistributor_base: Option<PhysicalAddress>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HardwareInfo {
    pub dtb_phys: DeviceTreeBlobPhysicalAddress,
    pub dtb_size: usize,
    memory_regions: [MemoryRegion; MAX_MEMORY_ARENAS],
    memory_region_count: usize,
    /// RAM regions declared by the DTB that did not fit in `memory_regions`.
    /// Non-zero means the kernel is operating with less RAM than firmware
    /// reported.
    pub dropped_memory_regions: usize,
    pub total_memory: usize,
    reserved_regions: [MemoryRegion; MAX_RESERVED_REGIONS],
    reserved_region_count: usize,
    pub dropped_reserved_regions: usize,
    pub timer_frequency: Option<Frequency>,
    pub cpu_count: usize,
    pub uart_base: Option<PhysicalAddress>,
    pub features: Features,
}

impl HardwareInfo {
    pub const fn empty(dtb_phys: DeviceTreeBlobPhysicalAddress) -> Self {
        Self {
            dtb_phys,
            dtb_size: 0,
            memory_regions: [MemoryRegion {
                base: PhysicalAddress::ZERO,
                size: 0,
            }; MAX_MEMORY_ARENAS],
            memory_region_count: 0,
            dropped_memory_regions: 0,
            total_memory: 0,
            reserved_regions: [MemoryRegion {
                base: PhysicalAddress::ZERO,
                size: 0,
            }; MAX_RESERVED_REGIONS],
            reserved_region_count: 0,
            dropped_reserved_regions: 0,
            timer_frequency: None,
            cpu_count: 0,
            uart_base: None,
            features: Features {
                hardware_random: false,
                interrupt_controller: None,
            },
        }
    }

    pub fn from_fdt(
        dtb_phys: DeviceTreeBlobPhysicalAddress,
        fdt: &Fdt<'_>,
        dtb_blob: &[u8],
    ) -> Self {
        let mut info = Self::empty(dtb_phys);
        info.dtb_size = fdt.total_size();
        info.collect_memory_regions(fdt);
        info.collect_reserved_regions(fdt, dtb_blob);
        info.timer_frequency = timer_frequency(fdt);
        info.cpu_count = cpu_count(fdt);
        info.features.hardware_random = has_hardware_random(fdt);
        info.features.interrupt_controller = interrupt_controller_info(fdt);
        info.uart_base = uart_base(fdt);
        info
    }

    pub fn memory_regions(&self) -> &[MemoryRegion] {
        &self.memory_regions[..self.memory_region_count]
    }

    pub fn reserved_regions(&self) -> &[MemoryRegion] {
        &self.reserved_regions[..self.reserved_region_count]
    }

    pub fn max_memory_end(&self) -> PhysicalAddress {
        self.memory_regions()
            .iter()
            .filter_map(|region| region.end())
            .max()
            .unwrap_or(PhysicalAddress::ZERO)
    }

    fn push_memory_region(&mut self, region: MemoryRegion) {
        if self.memory_region_count >= self.memory_regions.len() {
            self.dropped_memory_regions = self.dropped_memory_regions.saturating_add(1);
            return;
        }
        self.memory_regions[self.memory_region_count] = region;
        self.memory_region_count += 1;
        self.total_memory = self.total_memory.saturating_add(region.size);
    }

    fn push_reserved_region(&mut self, region: MemoryRegion) {
        if self.reserved_region_count >= self.reserved_regions.len() {
            self.dropped_reserved_regions = self.dropped_reserved_regions.saturating_add(1);
            return;
        }
        self.reserved_regions[self.reserved_region_count] = region;
        self.reserved_region_count += 1;
    }

    /// Collect RAM regions from `/memory` nodes and sort by size descending.
    ///
    /// The PMM initializes arenas in order. Largest first keeps metadata in the
    /// biggest pool before smaller regions are touched.
    fn collect_memory_regions(&mut self, fdt: &Fdt<'_>) {
        let root = fdt.root();
        let Some(memory) = root.find_node("/memory") else {
            return;
        };
        let Some(reg) = memory.reg() else {
            return;
        };

        for entry in reg.iter::<u64, u64>() {
            let Ok(entry) = entry else {
                continue;
            };
            let Some(region) = MemoryRegion::from_fdt_reg(entry.address, entry.len) else {
                continue;
            };
            self.push_memory_region(region);
        }

        // Largest first: arena metadata comes from the biggest pool before
        // smaller regions are touched.
        sort_regions_by_size(&mut self.memory_regions[..self.memory_region_count]);
    }

    fn collect_reserved_regions(&mut self, fdt: &Fdt<'_>, dtb_blob: &[u8]) {
        self.collect_memory_reservation_block(fdt, dtb_blob);
        self.collect_reserved_memory_node(fdt);
    }

    fn collect_memory_reservation_block(&mut self, fdt: &Fdt<'_>, dtb_blob: &[u8]) {
        let offset = fdt.header().memory_reserve_map_offset as usize;
        let Some(mut block) = dtb_blob.get(offset..) else {
            self.dropped_reserved_regions = self.dropped_reserved_regions.saturating_add(1);
            return;
        };

        while block.len() >= 16 {
            let Some(address) = read_be_u64(block) else {
                break;
            };
            let Some(size) = read_be_u64(&block[8..]) else {
                break;
            };
            if address == 0 && size == 0 {
                return;
            }
            let Some(region) = MemoryRegion::from_fdt_reg(address, size) else {
                self.dropped_reserved_regions = self.dropped_reserved_regions.saturating_add(1);
                block = &block[16..];
                continue;
            };
            self.push_reserved_region(region);
            block = &block[16..];
        }

        self.dropped_reserved_regions = self.dropped_reserved_regions.saturating_add(1);
    }

    fn collect_reserved_memory_node(&mut self, fdt: &Fdt<'_>) {
        let root = fdt.root();
        let Some(parent) = root.find_node("/reserved-memory") else {
            return;
        };

        for child in parent.children().iter() {
            let Some(reg) = child.reg() else {
                continue;
            };
            for entry in reg.iter::<u64, u64>() {
                let Ok(entry) = entry else {
                    continue;
                };
                let Some(region) = MemoryRegion::from_fdt_reg(entry.address, entry.len) else {
                    continue;
                };
                self.push_reserved_region(region);
            }
        }
    }
}

fn read_be_u64(bytes: &[u8]) -> Option<u64> {
    Some(u64::from_be_bytes([
        *bytes.first()?,
        *bytes.get(1)?,
        *bytes.get(2)?,
        *bytes.get(3)?,
        *bytes.get(4)?,
        *bytes.get(5)?,
        *bytes.get(6)?,
        *bytes.get(7)?,
    ]))
}

// Insertion sort is fine: MAX_MEMORY_ARENAS is 4 and this runs once at boot.
fn sort_regions_by_size(regions: &mut [MemoryRegion]) {
    for i in 1..regions.len() {
        let key = regions[i];
        let mut j = i;
        while j > 0 && regions[j - 1].size < key.size {
            regions[j] = regions[j - 1];
            j -= 1;
        }
        regions[j] = key;
    }
}

fn timer_frequency(fdt: &Fdt<'_>) -> Option<Frequency> {
    let cpus = fdt.root().find_node("/cpus")?;
    let prop = cpus.raw_property("timebase-frequency")?;
    parse_timer_frequency(prop.value).and_then(Frequency::try_from_hz)
}

fn parse_timer_frequency(prop: &[u8]) -> Option<u64> {
    match prop.len() {
        0..=3 => None,
        4..=7 => read_cells(prop, 1),
        _ => read_cells(prop, 2),
    }
}

fn cpu_count(fdt: &Fdt<'_>) -> usize {
    let Some(cpus) = fdt.root().find_node("/cpus") else {
        return 0;
    };

    cpus.children()
        .iter()
        .filter(|node| node.name().name == "cpu")
        .count()
}

fn first_cpu_node<'a>(fdt: &Fdt<'a>) -> Option<Node<'a>> {
    fdt.root()
        .find_node("/cpus")?
        .children()
        .iter()
        .find(|node| node.name().name == "cpu")
}

fn has_hardware_random(fdt: &Fdt<'_>) -> bool {
    let Some(cpu) = first_cpu_node(fdt) else {
        return false;
    };

    if let Some(prop) = cpu.raw_property("riscv,isa-extensions")
        && has_string_list_entry(prop.value, "zkr")
    {
        return true;
    }

    cpu.raw_property("riscv,isa")
        .map(|prop| isa_string_has_extension(trim_prop_string(prop.value), "zkr"))
        .unwrap_or(false)
}

fn has_string_list_entry(prop: &[u8], entry: &str) -> bool {
    prop.split(|byte| *byte == 0)
        .any(|item| !item.is_empty() && item == entry.as_bytes())
}

fn trim_prop_string(prop: &[u8]) -> &[u8] {
    prop.split(|byte| *byte == 0).next().unwrap_or(prop)
}

fn isa_string_has_extension(isa: &[u8], ext: &str) -> bool {
    if ext.is_empty() || isa.len() < ext.len() {
        return false;
    }

    let ext = ext.as_bytes();
    let mut pos = 0;
    while let Some(relative) = find_subslice(&isa[pos..], ext) {
        let idx = pos + relative;
        let before_ok = idx == 0 || isa[idx - 1] == b'_';
        let after = idx + ext.len();
        let after_ok = after == isa.len() || isa[after] == b'_';
        if before_ok && after_ok {
            return true;
        }
        pos = idx + 1;
    }
    false
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn interrupt_controller_info(fdt: &Fdt<'_>) -> Option<InterruptControllerInfo> {
    find_compatible(fdt, &["arm,gic-v3"])
        .and_then(|node| parse_gic_regs(node, 3))
        .or_else(|| {
            find_compatible(fdt, &["arm,cortex-a15-gic", "arm,gic-400"])
                .and_then(|node| parse_gic_regs(node, 2))
        })
}

fn parse_gic_regs(node: Node<'_>, version: u8) -> Option<InterruptControllerInfo> {
    let reg = node.reg()?;
    let mut entries = reg.iter::<u64, u64>();
    let distributor = entries.next()?.ok()?;
    let second = entries.next().and_then(Result::ok);
    let distributor_base = PhysicalAddress::try_from_u64(distributor.address)?;

    match version {
        2 => Some(InterruptControllerInfo::GicV2 {
            distributor_base,
            cpu_interface_base: second
                .and_then(|entry| PhysicalAddress::try_from_u64(entry.address)),
        }),
        3 => Some(InterruptControllerInfo::GicV3 {
            distributor_base,
            redistributor_base: second
                .and_then(|entry| PhysicalAddress::try_from_u64(entry.address)),
        }),
        _ => None,
    }
}

fn uart_base(fdt: &Fdt<'_>) -> Option<PhysicalAddress> {
    find_compatible(fdt, &["arm,pl011", "ns16550a"]).and_then(device_base)
}

fn device_base(node: Node<'_>) -> Option<PhysicalAddress> {
    node.reg()?
        .iter::<u64, u64>()
        .next()?
        .ok()
        .and_then(|entry| PhysicalAddress::try_from_u64(entry.address))
}

fn find_compatible<'a>(fdt: &Fdt<'a>, compatible: &[&str]) -> Option<Node<'a>> {
    fdt.root().all_compatible(compatible).next()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FDT_BEGIN_NODE: u32 = 1;
    const FDT_END_NODE: u32 = 2;
    const FDT_PROP: u32 = 3;
    const FDT_END: u32 = 9;

    #[test]
    fn returns_valid_region_slices() {
        let mut hw = HardwareInfo::empty(DeviceTreeBlobPhysicalAddress::new(0x4000_0000));
        hw.push_memory_region(MemoryRegion {
            base: PhysicalAddress::new(0x8000_0000),
            size: 0x1000_0000,
        });
        hw.push_reserved_region(MemoryRegion {
            base: PhysicalAddress::new(0x8000_0000),
            size: 0x20_0000,
        });

        assert_eq!(hw.memory_regions().len(), 1);
        assert_eq!(hw.reserved_regions().len(), 1);
        assert_eq!(hw.max_memory_end(), PhysicalAddress::new(0x9000_0000));
    }

    #[test]
    fn sorts_regions_by_size_descending() {
        let mut regions = [
            MemoryRegion {
                base: PhysicalAddress::new(0x1000),
                size: 100,
            },
            MemoryRegion {
                base: PhysicalAddress::new(0x2000),
                size: 500,
            },
            MemoryRegion {
                base: PhysicalAddress::new(0x3000),
                size: 200,
            },
        ];

        sort_regions_by_size(&mut regions);

        assert_eq!(regions[0].size, 500);
        assert_eq!(regions[1].size, 200);
        assert_eq!(regions[2].size, 100);
    }

    #[test]
    fn parses_timer_frequency_encodings() {
        assert_eq!(
            parse_timer_frequency(&[0x00, 0x98, 0x96, 0x80]),
            Some(10_000_000)
        );
        assert_eq!(
            parse_timer_frequency(&[0x00, 0x00, 0x00, 0x02, 0x54, 0x0b, 0xe4, 0x00]),
            Some(10_000_000_000)
        );
        assert_eq!(parse_timer_frequency(&[0x01, 0x02]), None);
    }

    #[test]
    fn detects_hardware_random_extension_forms() {
        assert!(has_string_list_entry(b"ima\0zkr\0", "zkr"));
        assert!(isa_string_has_extension(b"rv64imafd_zicsr_zkr", "zkr"));
        assert!(!isa_string_has_extension(b"rv64imafdzkr", "zkr"));
    }

    #[test]
    fn extracts_boot_hardware_info_from_fdt() {
        let blob = test_dtb();
        let fdt = Fdt::new_unaligned(&blob).unwrap();
        let hw =
            HardwareInfo::from_fdt(DeviceTreeBlobPhysicalAddress::new(0x4800_0000), &fdt, &blob);

        assert_eq!(hw.dtb_phys, DeviceTreeBlobPhysicalAddress::new(0x4800_0000));
        assert_eq!(hw.dtb_size, blob.len());
        assert_eq!(hw.memory_regions().len(), 2);
        assert_eq!(
            hw.memory_regions()[0],
            MemoryRegion {
                base: PhysicalAddress::new(0x8000_0000),
                size: 0x0800_0000,
            }
        );
        assert_eq!(hw.total_memory, 0x0c00_0000);
        assert_eq!(
            hw.reserved_regions(),
            &[MemoryRegion {
                base: PhysicalAddress::new(0x8f00_0000),
                size: 0x10_0000,
            }]
        );
        assert_eq!(hw.timer_frequency.map(Frequency::get), Some(10_000_000));
        assert_eq!(hw.cpu_count, 2);
        assert!(hw.features.hardware_random);
        assert_eq!(hw.uart_base, Some(PhysicalAddress::new(0x1000_0000)));
        assert_eq!(
            hw.features.interrupt_controller,
            Some(InterruptControllerInfo::GicV3 {
                distributor_base: PhysicalAddress::new(0x0800_0000),
                redistributor_base: Some(PhysicalAddress::new(0x080a_0000)),
            })
        );
    }

    #[test]
    fn extracts_header_memory_reservations_from_fdt() {
        let mut dtb = DtbBuilder::new();
        dtb.reserve(0x8100_0000, 0x20_0000);
        dtb.begin_node("");
        dtb.end_node();

        let blob = dtb.finish();
        let fdt = Fdt::new_unaligned(&blob).unwrap();
        let hw =
            HardwareInfo::from_fdt(DeviceTreeBlobPhysicalAddress::new(0x4800_0000), &fdt, &blob);

        assert_eq!(
            hw.reserved_regions(),
            &[MemoryRegion {
                base: PhysicalAddress::new(0x8100_0000),
                size: 0x20_0000,
            }]
        );
        assert_eq!(hw.dropped_reserved_regions, 0);
    }

    #[test]
    fn records_reserved_region_overflow() {
        let mut dtb = DtbBuilder::new();
        for index in 0..MAX_RESERVED_REGIONS + 1 {
            dtb.reserve(0x8100_0000 + (index as u64) * 0x10_0000, 0x1000);
        }
        dtb.begin_node("");
        dtb.end_node();

        let blob = dtb.finish();
        let fdt = Fdt::new_unaligned(&blob).unwrap();
        let hw =
            HardwareInfo::from_fdt(DeviceTreeBlobPhysicalAddress::new(0x4800_0000), &fdt, &blob);

        assert_eq!(hw.reserved_regions().len(), MAX_RESERVED_REGIONS);
        assert_eq!(hw.dropped_reserved_regions, 1);
    }

    fn test_dtb() -> Vec<u8> {
        let mut dtb = DtbBuilder::new();

        dtb.begin_node("");
        dtb.prop_u32("#address-cells", 2);
        dtb.prop_u32("#size-cells", 2);
        dtb.prop_str_list("compatible", &["bullfinch,test"]);

        dtb.begin_node("memory@80000000");
        dtb.prop_str("device_type", "memory");
        dtb.prop_cells(
            "reg",
            &[
                0,
                0x8000_0000,
                0,
                0x0800_0000,
                0,
                0x4000_0000,
                0,
                0x0400_0000,
            ],
        );
        dtb.end_node();

        dtb.begin_node("reserved-memory");
        dtb.prop_u32("#address-cells", 2);
        dtb.prop_u32("#size-cells", 2);
        dtb.begin_node("framebuffer@8f000000");
        dtb.prop_cells("reg", &[0, 0x8f00_0000, 0, 0x0010_0000]);
        dtb.end_node();
        dtb.end_node();

        dtb.begin_node("cpus");
        dtb.prop_u32("#address-cells", 1);
        dtb.prop_u32("#size-cells", 0);
        dtb.prop_u32("timebase-frequency", 10_000_000);
        dtb.begin_node("cpu@0");
        dtb.prop_str("device_type", "cpu");
        dtb.prop_str_list("riscv,isa-extensions", &["ima", "zkr"]);
        dtb.end_node();
        dtb.begin_node("cpu@1");
        dtb.prop_str("device_type", "cpu");
        dtb.end_node();
        dtb.end_node();

        dtb.begin_node("soc");
        dtb.prop_u32("#address-cells", 2);
        dtb.prop_u32("#size-cells", 2);
        dtb.begin_node("serial@10000000");
        dtb.prop_str_list("compatible", &["ns16550a"]);
        dtb.prop_cells("reg", &[0, 0x1000_0000, 0, 0x100]);
        dtb.end_node();
        dtb.begin_node("interrupt-controller@8000000");
        dtb.prop_str_list("compatible", &["arm,gic-v3"]);
        dtb.prop_cells(
            "reg",
            &[0, 0x0800_0000, 0, 0x1_0000, 0, 0x080a_0000, 0, 0x00f6_0000],
        );
        dtb.end_node();
        dtb.end_node();

        dtb.end_node();
        dtb.finish()
    }

    struct DtbBuilder {
        reserved: Vec<(u64, u64)>,
        structs: Vec<u8>,
        strings: Vec<u8>,
    }

    impl DtbBuilder {
        fn new() -> Self {
            Self {
                reserved: Vec::new(),
                structs: Vec::new(),
                strings: Vec::new(),
            }
        }

        fn reserve(&mut self, address: u64, size: u64) {
            self.reserved.push((address, size));
        }

        fn begin_node(&mut self, name: &str) {
            self.push_struct_u32(FDT_BEGIN_NODE);
            self.structs.extend_from_slice(name.as_bytes());
            self.structs.push(0);
            self.pad_struct();
        }

        fn end_node(&mut self) {
            self.push_struct_u32(FDT_END_NODE);
        }

        fn prop_u32(&mut self, name: &str, value: u32) {
            self.prop(name, &value.to_be_bytes());
        }

        fn prop_cells(&mut self, name: &str, cells: &[u32]) {
            let mut value = Vec::new();
            for cell in cells {
                value.extend_from_slice(&cell.to_be_bytes());
            }
            self.prop(name, &value);
        }

        fn prop_str(&mut self, name: &str, value: &str) {
            let mut bytes = Vec::from(value.as_bytes());
            bytes.push(0);
            self.prop(name, &bytes);
        }

        fn prop_str_list(&mut self, name: &str, values: &[&str]) {
            let mut bytes = Vec::new();
            for value in values {
                bytes.extend_from_slice(value.as_bytes());
                bytes.push(0);
            }
            self.prop(name, &bytes);
        }

        fn prop(&mut self, name: &str, value: &[u8]) {
            let name_offset = self.string_offset(name);
            self.push_struct_u32(FDT_PROP);
            self.push_struct_u32(value.len() as u32);
            self.push_struct_u32(name_offset);
            self.structs.extend_from_slice(value);
            self.pad_struct();
        }

        fn finish(mut self) -> Vec<u8> {
            self.push_struct_u32(FDT_END);

            const HEADER_LEN: usize = 40;
            let reserve_map_len = (self.reserved.len() + 1) * 16;
            let structs_offset = HEADER_LEN + reserve_map_len;
            let strings_offset = structs_offset + self.structs.len();
            let total_size = strings_offset + self.strings.len();

            let mut out = Vec::new();
            for word in [
                0xd00d_feed,
                total_size as u32,
                structs_offset as u32,
                strings_offset as u32,
                HEADER_LEN as u32,
                17,
                16,
                0,
                self.strings.len() as u32,
                self.structs.len() as u32,
            ] {
                out.extend_from_slice(&word.to_be_bytes());
            }
            for (address, size) in &self.reserved {
                out.extend_from_slice(&address.to_be_bytes());
                out.extend_from_slice(&size.to_be_bytes());
            }
            out.extend_from_slice(&[0; 16]);
            out.extend_from_slice(&self.structs);
            out.extend_from_slice(&self.strings);
            out
        }

        fn string_offset(&mut self, name: &str) -> u32 {
            let offset = self.strings.len() as u32;
            self.strings.extend_from_slice(name.as_bytes());
            self.strings.push(0);
            offset
        }

        fn push_struct_u32(&mut self, word: u32) {
            self.structs.extend_from_slice(&word.to_be_bytes());
        }

        fn pad_struct(&mut self) {
            while !self.structs.len().is_multiple_of(4) {
                self.structs.push(0);
            }
        }
    }
}
