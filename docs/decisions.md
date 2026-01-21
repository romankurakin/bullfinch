# Design Decisions

Architectural choices made for completed rungs. See `plan.md` for research.

## Format

Simplified [Architecture Decision Record](https://adr.github.io/) format.

Each entry answers three questions:

1. **What** was chosen
2. **What** was rejected (after "over")
3. **Why** this choice is better

Pattern: `**Topic:** Choice over alternative. Rationale.`

Only document actual choices between viable alternatives. Architecture-mandated
requirements (no alternative exists) don't belong here.

---

## Rung 1: Toolchain and Boot

**HAL:** Compile-time dispatch via conditional imports over runtime polymorphism.
Zero abstraction cost, dead code elimination for unused architectures.

**Boot:** Two-phase boot (physical → virtual) rather than direct higher-half
entry. Traps and console work before MMU, so early crashes are debuggable.

**Board config:** External board modules over hardcoded addresses. Adding a
board doesn't require modifying kernel code.

---

## Rung 2: Exception Handling

**Trap frame:** Uniform 288-byte layout across architectures over arch-specific
sizes. Common code can inspect registers without conditionals.

**IRQ fast path:** Partial register save (176/144 bytes) over full context (288).
Reduces interrupt latency. Full save only for synchronous exceptions that may
inspect callee-saved state.

**Assembly generation:** Derived offsets from struct layout over hardcoded
values. Single source of truth prevents assembly/struct desync when layout
changes.

---

## Rung 3: MMU and Abstraction Layer

**Virtual address size:** 39-bit on ARM64, Sv48 on RISC-V over larger options.
Simpler page tables, sufficient for educational kernel.

**Higher-half kernel:** Simultaneous identity + higher-half mapping over
sequential setup. Single page table switch, identity removed after jump.

---

## Rung 4: Timer and Clock Services

**Tick rate:** 100 Hz over higher frequencies (250, 1000 Hz). Balances
responsiveness against interrupt overhead. Standard choice (Linux default).

**Deadline strategy:** Absolute deadlines over relative intervals. Prevents
drift accumulation—relative offsets compound timing errors.

---

## Rung 5: Device Tree Parsing

**Parsing strategy:** Upfront extraction into static struct over lazy on-demand.
Avoids repeated parsing and chicken-egg with PMM initialization.

**Module separation:** Pure DTB library (fdt.zig) separate from kernel device
policy (hwinfo.zig). Library testable independently, reusable outside kernel.

---

## Rung 6: Physical Memory Allocator

**Strategy:** Free list with per-page metadata over bitmap or buddy system.
O(1) allocation and free, simpler than buddy while handling fragmentation.

**Metadata placement:** End of arena over beginning. Keeps low addresses free
for legacy DMA that requires sub-4GB memory.

**Debug:** Poison fills (0xDE) over zeroing. Use-after-free causes predictable
corruption (0xDEDEDEDE), making bugs obvious instead of silent.

---

## Rung 7: Kernel Object Allocator

**Strategy:** Fixed-size pools with embedded bitmap (Bonwick slab) over external
metadata. Self-contained slabs, no separate metadata allocator dependency.

**Allocation:** Bitmap scan via ctz over embedded free lists. Fast on modern
CPUs, simpler bookkeeping for fixed-size objects.

**Alignment:** Cache-line (64 bytes) over natural alignment. Wastes memory but
prevents false sharing on SMP—subtle bugs not worth the savings.

---

## Rung 8: Task Structures and Scheduler

**Thread struct:** Minimal fields over premature abstraction. Adding a field
later is trivial.

**Scheduler:** Fair scheduling over round-robin or priority queues. Weight-based
vruntime avoids starvation without complex rules. O(n) list scan now; optimize
to min-heap at Tickless Scheduling if needed.

**Preemption:** Preemptive from start over cooperative-first. Timer works,
catches concurrency bugs early.

**IPC field:** `blocked_on` now over adding at Synchronous IPC. Enables Liedtke
direct process switch. 8 bytes cost, avoids later refactor.

**Single-wait:** One wait pointer over wait block array. Multi-wait via
notification binding over Port object. Thread receives on
endpoint OR bound notification—2 primitives instead of 3.

**Rung 8 structs:**

```zig
const Process = struct { id: ProcessId, threads: ?*Thread };

const Thread = struct {
    id: ThreadId,
    process: *Process,
    state: State,
    context: arch.Context,
    trap_frame: *TrapFrame,
    kernel_stack: [*]u8,
    sched_next: ?*Thread,
    blocked_on: ?*WaitQueue,
    weight: u32,
    virtual_runtime: u64,
};
```

**Evolution:** +page_table/asid (Per-Task VM), +cpu (SMP), +sched_node (Tickless),
+bound_notification (Async), +exception_channel (Faults).

---
