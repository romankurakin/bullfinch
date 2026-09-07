# Design Decisions

This document records architectural choices for completed rungs and accepted
choices for the next implementation rung. See [the roadmap](plan.md) for research.

## Format

Entries use a simplified [Architecture Decision Record](https://adr.github.io/)
format.

Each entry answers three questions:

1. What was chosen?
2. What alternative was rejected (after "over")?
3. Why does the choice suit this project?

Pattern: `**Topic:** Choice over alternative. Rationale.`

Record only choices between viable alternatives. Omit requirements imposed by
the architecture when no alternative exists. Explain unavoidable consequences
of an earlier choice in that entry's rationale, not as separate decisions.

---

## Rung 1: Toolchain and Boot

**HAL:** Select architecture code through conditional imports at compile time
over runtime polymorphism. This adds no runtime dispatch cost and lets the
compiler remove unused architecture code.

**Boot:** Boot in two phases, physical then virtual, over direct higher-half
entry. Traps and the console work before the MMU is enabled, so developers can
diagnose early crashes.

**Board config:** Keep board configuration in external modules over hardcoded
addresses. Adding a board does not require changes to kernel code.

---

## Rung 2: Exception Handling

**Trap frame:** Use a uniform 288-byte layout across architectures over
architecture-specific sizes. Common code can inspect registers without
architecture conditionals.

**IRQ fast path:** Use partial IRQ frames (176/144 bytes) over full 288-byte trap
frames. The smaller frames reduce interrupt latency. Exception return still
restores interrupt state.

**Assembly layout:** Use frame sizes and field offsets over unchecked hardcoded
offsets. A layout mismatch fails the build.

---

## Rung 3: MMU and Abstraction Layer

**Virtual address size:** Use 39-bit addresses on ARM64 and Sv48 on RISC-V over
three-level paging on both architectures. Both choices give the kernel half
the same layout of 512 x 1 GiB slots. Sv39's upper half has only 256 slots.
The shared layout lets both architectures use the same physmap and stack-region
geometry.

**Higher-half kernel:** Set up identity and higher-half mappings together over
setting them up in sequence. This needs one page table switch. Remove the
identity mapping after the jump to the higher half.

---

## Rung 4: Timer and Clock Services

**Tick rate:** Use 100 Hz over higher frequencies (250, 1000 Hz). This balances
responsiveness against interrupt overhead and follows the standard Linux
default.

**Deadline strategy:** Use absolute deadlines over relative intervals. Relative
offsets compound timing errors. Absolute deadlines prevent that drift from
accumulating.

---

## Rung 5: Device Tree Parsing

**Parsing strategy:** Extract data into a static struct upfront over parsing it
on demand. This avoids repeated parsing and a circular dependency with PMM
initialization.

**Module separation:** Keep pure DTB parsing in `fdt` and kernel device policy in
`hwinfo`. The parsing library can be tested independently and reused outside
boot policy.

---

## Rung 6: Physical Memory Allocator

**Strategy:** Use a free list with per-page metadata over a bitmap or buddy
system. Allocation and free take O(1) time. The free list handles fragmentation
with less complexity than a buddy system.

**Metadata placement:** Use the highest safe span in an arena over its beginning.
This keeps low addresses free for legacy DMA and avoids firmware and kernel
reservations.

**Debug:** Fill freed memory with a poison value (0xDE) in debug builds over
zeroing it. Use-after-free exposes a recognizable pattern (0xDEDEDEDE), making
the bug easier to detect. Release builds skip the fill on each free, matching
Linux's opt-in page poisoning.

**Contiguous free:** Let the caller own the length (Zircon) over storing it in PMM
(Linux compound pages). PMM validates the head flag and page state. The caller
owns the slice size, which keeps per-page metadata small.

---

## Rung 7: Kernel Object Allocator

**Strategy:** Use fixed-size pools with an embedded bitmap (Bonwick slab) over
external metadata. Each slab holds its own metadata, so it needs no separate
metadata allocator.

**Allocation:** Scan the bitmap with ctz (count trailing zeros) over embedded
free lists. This is fast on modern CPUs and simplifies bookkeeping for
fixed-size objects.

**Alignment:** Use cache-line alignment (64 bytes) over natural alignment. This
costs memory but prevents false sharing on SMP. Avoiding those subtle problems
is worth the extra memory.

---

## Rung 8: Task Structures and Scheduler

**Thread struct:** Keep only the fields needed now over adding abstractions
early. Adding a field later is easy.

**Scheduler:** Use fair scheduling over round-robin or priority queues. Virtual
runtime (vruntime) adjusted by thread weight avoids starvation without complex
rules. Use an O(n) list scan now. Switch to a min-heap at Tickless Scheduling
if needed.

**Preemption:** Start with preemptive scheduling over adding it after cooperative
scheduling. The timer already works, and preemption exposes concurrency bugs
early.

**IPC field:** Add `blocked_on` now over waiting until Synchronous IPC. This
supports Liedtke's direct process switch. It costs 8 bytes and avoids a later
refactor.

**Single-wait:** Use one wait pointer over an array of wait blocks. A thread
receives on an endpoint or its bound notification. This uses 2 primitives
instead of 3.

---

## Rung 9: FP/SIMD State

**Kernel FP/SIMD:** Soft-float targets over kernel-mode FP/SIMD. Kernel code avoids
user-state ownership, and accidental FP use traps instead of corrupting state.
Reverses the earlier "EL1 FP/SIMD allowed" choice.

**User FP ownership:** CPU-resident state across traps with eager transfer at
thread switches over per-trap save/restore or lazy cross-thread ownership.
Avoids trap-time register transfers and a per-CPU owner/migration protocol.
ARM64 tracks state in software; RISC-V also uses `sstatus.FS` to skip clean saves.

**User FP activation and storage:** Trap on first use over enabling every thread,
but store images inline over allocating in the trap. Non-FP threads avoid state
transfers; first use initializes registers for their new owner. With a bounded
thread table, avoiding trap-path allocation is worth 528 bytes per ARM64 thread
or 272 bytes per RISC-V thread.

**Vector extensions:** No SVE, SME, or RVV over partial support. Each requires
additional state handling.

---
