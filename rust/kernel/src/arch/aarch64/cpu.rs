//! ARM64 CPU primitives.
//!
//! See ARM Architecture Reference Manual, DDI 0487J, sections D1.2 (DAIF),
//! D6.2 (barriers), D13.2 (system registers).

use core::arch::asm;

const DAIF_IRQ_MASK: u8 = 0b0010;

pub fn disable_interrupts() -> bool {
    let daif: usize;
    // SAFETY: Reading DAIF has no memory effect and tells us whether IRQ was
    // already masked before this guard.
    unsafe {
        asm!("mrs {daif}, daif", daif = out(reg) daif, options(nomem, nostack, preserves_flags))
    };
    // SAFETY: DAIFSet with bit 1 masks IRQ exceptions on the current CPU. We
    // intentionally omit `nomem`: masking interrupts is the boundary the
    // compiler must not sink memory accesses across, and the IRQ handler that
    // runs *before* masking takes effect can observe prior stores.
    unsafe {
        asm!("msr daifset, {mask}", mask = const DAIF_IRQ_MASK, options(nostack, preserves_flags))
    };
    daif & (1 << 7) == 0
}

pub fn enable_interrupts() {
    // SAFETY: DAIFClr with bit 1 unmasks IRQ exceptions on the current CPU.
    // No `nomem`: a handler may fire before the next instruction commits and
    // must observe all prior stores.
    unsafe {
        asm!("msr daifclr, {mask}", mask = const DAIF_IRQ_MASK, options(nostack, preserves_flags))
    };
}

#[allow(dead_code)]
pub fn restore_interrupts(was_enabled: bool) {
    if was_enabled {
        enable_interrupts();
    }
}

#[allow(dead_code)]
pub fn spin_wait() {
    core::hint::spin_loop();
}

/// DSB ISH — required before TLB invalidation and after page-table writes.
pub fn data_sync_barrier_inner_shareable() {
    // SAFETY: DSB ISH completes prior memory accesses before continuing.
    unsafe { asm!("dsb ish", options(nomem, nostack, preserves_flags)) };
}

pub fn data_sync_barrier_system() {
    // SAFETY: DSB SY for MMIO or unknown shareability domain handoffs.
    unsafe { asm!("dsb sy", options(nomem, nostack, preserves_flags)) };
}

/// ISB — flushes the pipeline after translation or system-register changes.
pub fn instruction_barrier() {
    // SAFETY: ISB flushes the pipeline.
    unsafe { asm!("isb", options(nomem, nostack, preserves_flags)) };
}

fn wait_for_interrupt() {
    // SAFETY: WFI suspends the current CPU.
    unsafe { asm!("wfi", options(nomem, nostack, preserves_flags)) };
}

pub fn halt() -> ! {
    loop {
        wait_for_interrupt();
    }
}
