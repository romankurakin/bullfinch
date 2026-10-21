use super::*;
use crate::{boot::DeviceTreeBlobPhysicalAddress, fdt::Fdt, hwinfo::HardwareInfo};
use std::{boxed::Box, panic::catch_unwind, sync::Mutex, vec::Vec};

struct Mappings {
    mapped: Vec<(VirtualAddress, PhysicalAddress)>,
    unmapped: Vec<VirtualAddress>,
    map_calls: usize,
    unmap_calls: usize,
    fail_map: Option<usize>,
    fail_unmap: Option<usize>,
}

static MAPPINGS: Mutex<Mappings> = Mutex::new(Mappings {
    mapped: Vec::new(),
    unmapped: Vec::new(),
    map_calls: 0,
    unmap_calls: 0,
    fail_map: None,
    fail_unmap: None,
});

fn prepare(fail_map: Option<usize>, fail_unmap: Option<usize>) {
    let mut mappings = MAPPINGS.lock().unwrap();
    mappings.unmapped.clear();
    mappings.map_calls = 0;
    mappings.unmap_calls = 0;
    mappings.fail_map = fail_map;
    mappings.fail_unmap = fail_unmap;
}

fn region_base() -> VirtualAddress {
    VirtualAddress::new(0x4000_0000)
}

fn map_page(virtual_address: VirtualAddress, physical: PhysicalAddress) -> Result<(), MapError> {
    let mut mappings = MAPPINGS.lock().unwrap();
    mappings.map_calls += 1;
    if mappings.fail_map == Some(mappings.map_calls) {
        return Err(MapError::OutOfMemory);
    }
    assert!(!mappings.mapped.iter().any(|(va, _)| *va == virtual_address));
    mappings.mapped.push((virtual_address, physical));
    Ok(())
}

fn unmap_page(virtual_address: VirtualAddress) -> Result<PhysicalAddress, UnmapError> {
    // Each case uses every free page. None may return to PMM before all
    // successful mappings have been removed, even if a later unmap fails.
    assert_eq!(pmm::free_pages(), 0);
    let mut mappings = MAPPINGS.lock().unwrap();
    mappings.unmap_calls += 1;
    if mappings.fail_unmap == Some(mappings.unmap_calls) {
        return Err(UnmapError::NotMapped);
    }
    let index = mappings
        .mapped
        .iter()
        .position(|(va, _)| *va == virtual_address)
        .expect("only successfully mapped pages should be unmapped");
    let (_, physical) = mappings.mapped.remove(index);
    mappings.unmapped.push(virtual_address);
    Ok(physical)
}

fn create_stack() -> Result<KernelStack, StackError> {
    KernelStack::create_mapped(region_base, map_page, unmap_page)
}

fn assert_slot_reusable(index: usize) {
    let slot = KernelStackSlot::alloc().unwrap();
    assert_eq!(slot.index(), index);
}

fn assert_slot_reserved(index: usize) {
    let mask = 1usize << (index % STACK_SLOT_WORD_BITS);
    assert_ne!(
        STACK_SLOTS.lock().words[index / STACK_SLOT_WORD_BITS] & mask,
        0
    );
}

fn memory_info(base: PhysicalAddress, size: usize) -> HardwareInfo {
    // A minimal DTB with one memory node and 64-bit address and size cells.
    let structure: [u32; 23] = [
        1,
        0, // Root node.
        3,
        4,
        0,
        2, // #address-cells = 2.
        3,
        4,
        15,
        2, // #size-cells = 2.
        1,
        0x6d65_6d6f,
        0x7279_0000, // memory node.
        3,
        16,
        27, // reg property.
        (base.get() as u64 >> 32) as u32,
        base.get() as u32,
        0,
        size as u32,
        2,
        2,
        9, // End both nodes and the structure block.
    ];
    let strings = b"#address-cells\0#size-cells\0reg\0";
    let structure_bytes = core::mem::size_of_val(&structure);
    let strings_offset = 56 + structure_bytes;
    let mut blob = Vec::new();
    for word in [
        0xd00d_feed,
        (strings_offset + strings.len()) as u32,
        56,
        strings_offset as u32,
        40,
        17,
        16,
        0,
        strings.len() as u32,
        structure_bytes as u32,
    ] {
        blob.extend_from_slice(&word.to_be_bytes());
    }
    blob.extend_from_slice(&[0; 16]);
    for word in structure {
        blob.extend_from_slice(&word.to_be_bytes());
    }
    blob.extend_from_slice(strings);
    HardwareInfo::from_fdt(
        DeviceTreeBlobPhysicalAddress::new(0),
        &Fdt::new(&blob).unwrap(),
    )
    .unwrap()
}

#[test]
fn stack_uses_fragmented_pages_and_preserves_ownership_during_teardown() {
    #[repr(align(4096))]
    struct Backing([u8; PAGE_SIZE * 16]);

    fn identity(address: PhysicalAddress) -> Option<VirtualAddress> {
        Some(VirtualAddress::new(address.get()))
    }

    // This is the only host test using global PMM. Its backing remains live
    // after the test because PMM retains pointers to its pages and metadata.
    let mut backing = Box::new(Backing([0; PAGE_SIZE * 16]));
    let base = PhysicalAddress::new(backing.0.as_mut_ptr() as usize);
    let _ = Box::into_raw(backing);
    let size = core::mem::size_of::<Backing>();
    let info = memory_info(base, size);
    // SAFETY: The leaked, page-aligned buffer is exclusively owned by PMM.
    // The identity mapping covers the whole buffer for the process lifetime.
    unsafe {
        pmm::init(
            &info,
            PhysicalAddress::ZERO,
            PhysicalAddress::ZERO,
            base.checked_add(size).unwrap(),
            identity,
        )
    }
    .unwrap();

    let mut held: Vec<_> = (0..pmm::free_pages()).map(|_| pmm::alloc_page()).collect();
    assert!(held.iter().all(Option::is_some));
    assert_eq!(pmm::free_pages(), 0);
    let physical = [
        held[0].as_ref().unwrap().physical_address().unwrap(),
        held[2].as_ref().unwrap().physical_address().unwrap(),
    ];
    drop(held[0].take());
    drop(held[2].take());
    assert_eq!(pmm::free_pages(), 2);
    assert!(pmm::alloc_contiguous(2, PAGE_SIZE.trailing_zeros() as u8).is_none());

    prepare(None, None);
    let stack = create_stack().unwrap();
    let slot = stack.slot.as_ref().unwrap().index();
    let bottom = region_base()
        .checked_add(slot * KERNEL_STACK_SLOT_SIZE + KERNEL_STACK_GUARD_SIZE)
        .unwrap();
    let upper = bottom.checked_add(PAGE_SIZE).unwrap();
    assert_eq!(stack.base(), bottom);
    assert_eq!(stack.top(), bottom.checked_add(KERNEL_STACK_SIZE).unwrap());
    assert_eq!(stack.size(), KERNEL_STACK_SIZE);
    assert_eq!(
        MAPPINGS.lock().unwrap().mapped,
        [(bottom, physical[0]), (upper, physical[1])]
    );
    drop(stack);
    assert_eq!(MAPPINGS.lock().unwrap().unmapped, [upper, bottom]);
    assert!(MAPPINGS.lock().unwrap().mapped.is_empty());
    assert_eq!(pmm::free_pages(), 2);
    assert_slot_reusable(slot);

    // Failure to allocate the second page removes the first mapping.
    let spare = pmm::alloc_page().unwrap();
    prepare(None, None);
    assert!(matches!(create_stack(), Err(StackError::OutOfMemory)));
    assert_eq!(MAPPINGS.lock().unwrap().map_calls, 1);
    assert_eq!(MAPPINGS.lock().unwrap().unmapped, [bottom]);
    assert!(MAPPINGS.lock().unwrap().mapped.is_empty());
    assert_eq!(pmm::free_pages(), 1);
    assert_slot_reusable(slot);
    drop(spare);

    // A failed map still owns its page, but only the first page was mapped.
    prepare(Some(2), None);
    assert!(matches!(
        create_stack(),
        Err(StackError::Map(MapError::OutOfMemory))
    ));
    assert_eq!(MAPPINGS.lock().unwrap().map_calls, 2);
    assert_eq!(MAPPINGS.lock().unwrap().unmapped, [bottom]);
    assert!(MAPPINGS.lock().unwrap().mapped.is_empty());
    assert_eq!(pmm::free_pages(), 2);
    assert_slot_reusable(slot);

    // Failed rollback keeps both pages and the slot reserved.
    prepare(Some(2), Some(1));
    assert!(catch_unwind(create_stack).is_err());
    assert_eq!(MAPPINGS.lock().unwrap().mapped.len(), 1);
    assert!(MAPPINGS.lock().unwrap().unmapped.is_empty());
    assert_eq!(pmm::free_pages(), 0);
    assert_slot_reserved(slot);

    // Normal teardown also keeps every page if a later unmap fails.
    drop(held[4].take());
    drop(held[6].take());
    prepare(None, Some(2));
    let stack = create_stack().unwrap();
    let next_slot = stack.slot.as_ref().unwrap().index();
    assert_ne!(next_slot, slot);
    assert!(catch_unwind(|| drop(stack)).is_err());
    assert_eq!(MAPPINGS.lock().unwrap().unmapped.len(), 1);
    assert_eq!(MAPPINGS.lock().unwrap().mapped.len(), 2);
    assert_eq!(pmm::free_pages(), 0);
    assert_slot_reserved(next_slot);
}
