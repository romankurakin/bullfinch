# Design Decisions

Decisions made for completed rungs. See `plan.md` for research questions.

---

## Rung 1: Toolchain and Boot

**HAL approach:** Compile-time conditional imports via `@import("board")` and
arch modules. No vtables or runtime dispatch.

**Boot phases:** Two-phase boot - physInit() before MMU, virtInit() after.
Kernel imports HAL, HAL re-exports arch abstractions.

**Board config:** External board module provides KERNEL_PHYS_LOAD and
KERNEL_VIRT_BASE constants.

---

## Rung 2: Exception Handling

**Trap frame:** 288 bytes on both architectures, 16-byte aligned.

- ARM64: 31 GP regs + SP + ELR + SPSR + ESR + FAR
- RISC-V: 31 regs (x1-x31) + SP + SEPC + SSTATUS + SCAUSE + STVAL

**IRQ optimization:** Fast-path saves only caller-saved registers (ARM64: x0-x18,
x30 = 176 bytes). Full context only for sync traps.

**Vector table:** ARM64 uses 2KB-aligned table with 128-byte entries. RISC-V
uses vectored mode with base+offset jumps.

---

## Rung 3: MMU and Abstraction Layer

**Page table format:**

- ARM64: 39-bit VA, 3-level (L1/L2/L3), TTBR0 (user) + TTBR1 (kernel) split
- RISC-V: Sv48, 48-bit VA, 4-level, single SATP register

**Higher-half strategy:** Boot sets up identity mapping AND higher-half
simultaneously using 1GB blocks. After jump to virtual address,
removeIdentityMapping() clears low entries.

**TLB barriers:**

- ARM64: DSB ishst → TLBI → DSB ish → ISB
- RISC-V: fence rw,rw → sfence.vma (local only, TODO: IPI for SMP)

---

## Rung 4: Timer and Clock Services

**Frequency discovery:**

- ARM64: Read CNTFRQ_EL0 register directly (firmware sets it)
- RISC-V: Read /cpus/timebase-frequency from DTB

**Tick rate:** 100 Hz (10ms intervals), absolute deadlines to prevent drift.

**Interrupt source:**

- ARM64: PPI 30 via Generic Timer CNTP registers
- RISC-V: SBI TIME extension (sbi.setTimer)

---

## Rung 5: Device Tree Parsing

**Strategy:** Lazy parsing via libfdt C bindings. No upfront scanning.

**Parsed properties:**

- /memory reg → RAM regions
- /cpus/timebase-frequency → timer (RISC-V)
- GIC compatible nodes → interrupt controller base addresses
- /reserved-memory → regions to exclude from PMM

**Cell handling:** Respects #address-cells and #size-cells per node.

---

## Rung 6: Physical Memory Allocator

**Strategy:** Free list with per-page metadata.

**Features:** Leak detection, SMP-ready locking (spinlock protected).

---

## Rung 7: Kernel Object Allocator

**Strategy:** Fixed-size slab pools (Bonwick pattern).

**Structure:** 4KB pages with embedded metadata - backpointer at offset 0,
bitmap in slot 0.

**Alignment:** Cache-line aligned (64 bytes) to prevent false sharing on SMP.

**Allocation:** O(ctz) bitmap scan for first free slot.

**Deallocation:** O(1) - mask pointer to page, read backpointer, set bitmap bit.
Double-free detection enabled.
