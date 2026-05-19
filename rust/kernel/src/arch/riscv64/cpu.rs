//! RISC-V CPU primitives.
//!
//! See RISC-V Privileged Architecture Spec (20211203), chapters 3 (CSRs),
//! 3.1.6.1 (sstatus.SIE), and the Memory-Consistency Model.

use core::arch::asm;

const SUPERVISOR_INTERRUPT_ENABLE: usize = 1 << 1;

#[allow(dead_code, reason = "used by the library CPU backend")]
pub fn disable_interrupts() -> bool {
    let sstatus: usize;
    // SAFETY: Reading sstatus is local hart state. SIE records whether
    // supervisor interrupts were enabled before this guard.
    unsafe {
        asm!("csrr {sstatus}, sstatus", sstatus = out(reg) sstatus, options(nomem, nostack, preserves_flags))
    };
    // SAFETY: Clearing sstatus.SIE masks supervisor interrupts. No `nomem`:
    // the boundary is observable to handlers, so the compiler must not sink
    // memory accesses across it.
    unsafe {
        asm!(
            "csrc sstatus, {mask}",
            mask = in(reg) SUPERVISOR_INTERRUPT_ENABLE,
            options(nostack, preserves_flags)
        );
    }
    sstatus & SUPERVISOR_INTERRUPT_ENABLE != 0
}

pub fn enable_interrupts() {
    // SAFETY: Setting sstatus.SIE enables supervisor interrupts. No `nomem`:
    // a handler may fire before the next instruction commits and must observe
    // all prior stores.
    unsafe {
        asm!(
            "csrs sstatus, {mask}",
            mask = in(reg) SUPERVISOR_INTERRUPT_ENABLE,
            options(nostack, preserves_flags)
        );
    }
}

#[allow(
    dead_code,
    reason = "used by spinlock guards through the library CPU backend"
)]
pub fn restore_interrupts(was_enabled: bool) {
    if was_enabled {
        enable_interrupts();
    }
}

#[allow(
    dead_code,
    reason = "used by spin loops through the library CPU backend"
)]
pub fn spin_wait() {
    // SAFETY: PAUSE is a hint instruction. On CPUs that ignore it, it behaves
    // like a no op in the polling loop.
    unsafe {
        asm!(
            ".insn i 0x0F, 0, x0, x0, 0x10",
            options(nomem, nostack, preserves_flags)
        )
    };
}

/// The RISC V read write fence is required after page table writes and before
/// SFENCE VMA.
pub fn fence_rw_rw() {
    // SAFETY: Orders page table writes before subsequent translation.
    unsafe { asm!("fence rw, rw", options(nomem, nostack, preserves_flags)) };
}

fn wait_for_interrupt() {
    // SAFETY: WFI suspends the current hart.
    unsafe { asm!("wfi", options(nomem, nostack, preserves_flags)) };
}

pub fn halt() -> ! {
    loop {
        wait_for_interrupt();
    }
}
