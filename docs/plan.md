# Bullfinch OS Development Plan

Architecture: ARM64 and RISC-V with hardware abstraction layer

Kernel Type: MINIX-style microkernel, small kernel with userspace services

Capability Model: Zircon-inspired capabilities (simplified for educational use, seL4 ideas referenced)

User Programs: WebAssembly runtime with WASI. No POSIX compatibility layer.

Process Model: Spawn-only (no fork). Explicit capability passing at process creation.

Thread Model: Zircon-style separation — process owns address space and handle table, threads execute within process.

Development Environment: Cross-compile from host. QEMU for initial testing, then real hardware (Raspberry Pi 5, Orange RV2).

Goal: Educational OS for personal learning, not production use.

Named after the bullfinch, a northern bird that flourishes in harsh conditions — a symbol of resilience and grace.

---

## Implementation Phases

### Phase 1: Foundation

#### Rung 0-1: Toolchain and Boot

Set up cross-compilation for both architectures. Implement UART output and boot banner. Define HAL interfaces before implementing either architecture.

Reading:

- RISC-V Privileged Spec: boot sequence
- ARMv8 Reference Manual: boot and UART sections

#### Rung 2: Exception Handling

Implement trap handlers for both architectures with register dumps. Add kernel debug output infrastructure (printf, panic).

Reading:

- OSTEP Chapter 6 (Limited Direct Execution)
- ARM64 Procedure Call Standard
- RISC-V Calling Convention

#### Rung 3: MMU and Abstraction Layer

Enable paging with identity mapping. Introduce HAL isolating architecture-specific code for MMU.

Reading:

- OSTEP Chapters 14-20
- RISC-V Sv39 specification
- ARM64 four-level page table specification

#### Rung 4: Timer and Clock Services

Implement timer interrupts. Add basic clock syscalls for monotonic time. Timer hardware generates IRQs that trigger tick handlers — required for preemptive scheduling in Phase 2.

Reading:

- OSDI3 Section 2.8 (The Clock Task in MINIX 3)
- RISC-V SBI timer specification
- ARM64 generic timer specification
- Zircon clock documentation

#### Rung 5: Device Tree Parsing

Integrate libfdt to parse Flattened Device Tree (FDT/DTB) and discover hardware at runtime. Extract memory regions, interrupt controller configuration (GIC/PLIC), and peripheral addresses. Required before physical memory allocator — must know available RAM and reserved regions from DTB.

Reading:

- Devicetree Specification
- libfdt API documentation

---

### Phase 2: Memory and Scheduling

#### Rung 6: Physical Memory Allocator

Implement page allocator with leak detection. Research allocator strategies (bitmap, buddy, free list).

Reading:

- OSDI3 Section 4.1 (basic memory management)

#### Rung 7: Kernel Object Allocator

Implement slab or pool allocator for fixed-size kernel object allocation. All kernel objects (tasks, handles, VMOs, channels) need efficient allocation.

Reading:

- Bonwick "The Slab Allocator" (USENIX 1994)

#### Rung 8: Task Structures and Scheduler

Define task/thread data structures. Document which registers to save per architecture. Build scheduler — start cooperative, add preemptive using timer interrupts. Implement direct process switch for IPC optimization (sender donates timeslice to receiver).

Reading:

- OSTEP Chapter 4 (Process abstraction)
- OSTEP Chapter 7 (Scheduling)
- OSDI3 Sections 2.1 (process concepts), 2.4 (scheduling)

#### Rung 9: Per-Task Virtual Memory

Implement address space isolation with ASID support.

Reading:

- OSDI3 Sections 4.3, 4.5, 4.7-4.8 (virtual memory, MINIX memory manager)

---

### Phase 3: Capability System and Core Kernel Objects

#### Rung 10: Kernel Object Model

Establish core pattern: kernel objects are reference-counted, destroyed at zero. All system resources represented as capabilities — no hidden kernel resources.

Reading:

- Zircon kernel object documentation
- seL4 manual (object lifecycle, capability spaces)

#### Rung 11: Handle Tables

Implement per-process handle table. Handles are indices into per-process tables, each entry contains pointer to kernel object plus rights bitmap.

Reading:

- OSDI3 Section 5.6.7 (file descriptors)
- Zircon handle documentation

#### Rung 12: Rights and Validation

Add rights to handle entries. Implement validation in syscall paths. Rights are per-handle, not per-object — same object can have multiple handles with different rights.

Reading:

- OSDI3 Section 5.5 (protection mechanisms)
- Zircon rights documentation

#### Rung 13: Derivation and Revocation

Handle derivation with attenuation (can only remove rights, never add). Research revocation strategies (seL4 CDT vs Zircon flat model).

Reading:

- seL4 manual (capability derivation, CDT)
- capDL paper

#### Rung 14: Memory Objects (VMOs)

Implement VMO kernel object for physical memory management. Support mapping and direct access. VMOs must precede IPC — IPC buffers are memory-backed. Process creation requires VMO for vDSO mapping.

Reading:

- OSTEP Chapter 19 (TLBs)
- Zircon VMO documentation

#### Rung 15: Address Space Management (VMAR)

Implement virtual memory address region management. Processes map VMOs into their address space through VMAR operations.

Reading:

- Zircon VMAR documentation
- seL4 VSpace management

#### Rung 16: Synchronous IPC

Build message-passing IPC. Liedtke's research: IPC is the central organizing principle. Key optimizations: direct process switch, register-based message passing, lazy scheduling, combined syscalls (call = send+receive).

Reading:

- Liedtke SOSP 1993 (Improving IPC by Kernel Design)
- Liedtke SOSP 1995 (On µ-Kernel Construction)
- OSDI3 Section 2.2 (MINIX message passing)

#### Rung 17: Handle Transfer

Extend IPC to move handles between processes. Handle removed from sender table, added to receiver table atomically.

Reading:

- Zircon channel documentation (handle transfer)

#### Rung 18: Async Notifications

Implement notification object for async signaling. Used for event notification without full IPC weight — essential for interrupt delivery. Userspace builds synchronization primitives (mutexes) on top of notifications + atomics.

Reading:

- seL4 manual (Notification objects)
- Zircon signals documentation

#### Rung 19: Fault Handling

Define fault delivery to userspace via IPC. Research seL4 fault endpoints vs Zircon exception channels.

Reading:

- Zircon exception handling
- seL4 fault endpoints

#### Rung 20: Hardware IRQ Objects

Bind hardware interrupts to notifications. Kernel ISR masks interrupt, signals notification. Userspace driver waits, handles, acks to unmask.

Reading:

- OSTEP Chapter 36 (I/O devices)
- OSDI3 Sections 2.6.8, 3.4.1 (MINIX interrupt handling)
- seL4 IRQHandler documentation
- RISC-V PLIC, ARM GIC specs

#### Rung 21: Memory Sharing

VMO sharing via handle duplication with reference counting. Research COW clone semantics (optional).

Reading:

- Zircon VMO clone documentation

#### Rung 22: Process Creation

Implement spawn syscall. Program loading is entirely userspace — kernel provides building blocks only. Parent passes all needed capabilities at spawn — no global namespace, no service discovery.

Reading:

- Zircon process_create, process_start
- "A fork() in the road" (HotOS 2019)

---

### Phase 4: Core Services in Userspace

### Rung 23: Initial Bootstrap

Kernel creates init process with bootstrap channel containing all initial capabilities (root job, vDSO VMO, boot image VMO). Init implements ELF loader, spawns core services, passes capabilities explicitly.

Reading:

- Zircon userboot documentation
- seL4 BootInfo structure

#### Rung 24: Process Manager

Userspace process lifecycle server. Handles spawn requests, creates process via kernel syscalls, passes capability set to new process. No PIDs — capabilities are the only process naming.

Reading:

- OSDI3 Section 2.3 (MINIX PM)
- Zircon process creation

### Rung 25: Device Manager

Device enumeration from devicetree. Distribute IRQ capabilities and MMIO regions (as VMOs) to drivers. Start with UART as first userspace driver.

Reading:

- OSDI3 Section 3.5 (MINIX drivers)
- Zircon driver model

### Rung 26: Filesystem Server

Implement simple filesystem server (ramfs initially). Apps get channel to filesystem directly at spawn — no VFS routing layer. Filesystem server IS the interface.

Reading:

- OSDI3 Sections 5.6-5.7 (MINIX FS)
- Plan 9 file protocol

---

### Phase 5: User Programs (WASM/WASI)

### Rung 27: WASM Runtime Integration

Embed WASM interpreter as userspace process. wasm3 recommended — lightweight (~64KB), pure C, no JIT complexity. Map WASM linear memory to VMO.

Reading:

- WASM specification
- wasm3 embedding documentation

### Rung 28: WASI Syscall Layer

Implement WASI subset. WASI aligns with capability model: file access requires passing descriptors with permissions, each WASI capability maps to microkernel handle.

Reading:

- WASI specification

### Rung 29: First WASM Application

Hello world end-to-end: kernel -> init -> PM -> WASM runtime -> .wasm -> WASI fd_write -> filesystem channel -> UART driver -> output.

---

## Phase 6: Hardening and Extensions (Future)

TBD: multi-core, tickless scheduling, real filesystems, network stack, virtio drivers, hardware testing.

---

## Reading References

### Core Operating Systems

- OSTEP — <https://pages.cs.wisc.edu/~remzi/OSTEP>
- OSDI3 — Operating Systems: Design & Implementation, 3rd ed. (Tanenbaum/Woodhull)
- Plan 9 Papers — <https://plan9.io/wiki/plan9/papers/index.html>

### Architecture

- [RISC-V Privileged Specification](https://github.com/riscv/riscv-isa-manual/releases/tag/Priv-v1.12), Version 20211203 (v1.12 ratified)
- [RISC-V SBI Specification v3.0](https://github.com/riscv-non-isa/riscv-sbi-doc/releases/tag/v3.0), 2025-07-16 (ratified)
- [ARM Architecture Reference Manual](https://developer.arm.com/documentation/ddi0487/maa) (DDI 0487M.a.a), ARMv8-A / ARMv9-A
- [ARM GIC Architecture Specification](https://developer.arm.com/documentation/ihi0069/hb) (IHI 0069H.b), GICv3.3/v4.2
- [ARM GIC-400 TRM](https://developer.arm.com/documentation/ddi0471/b) (DDI 0471B) — GICv2 for Pi 5

### Capability Systems

- Zircon Kernel — <https://fuchsia.dev/fuchsia-src/concepts/kernel>
- seL4 Reference Manual — <https://sel4.systems/Learn>
- seL4 Tutorials — <https://docs.sel4.systems/Tutorials>
- capDL Paper — <https://docs.sel4.systems/projects/capdl/>

### Microkernel IPC

- Liedtke SOSP 1993 — Improving IPC by Kernel Design
- Liedtke SOSP 1995 — On µ-Kernel Construction
- "A fork() in the road" — HotOS 2019

### Devicetree

- Devicetree Specification — <https://devicetree.org/specifications>

### Other

- Bonwick "The Slab Allocator" (USENIX 1994)
- WASM Specification — <https://webassembly.github.io/spec>
- WASI Specification — <https://wasi.dev>
