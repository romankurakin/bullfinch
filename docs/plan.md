# Bullfinch Development Plan

Educational microkernel inspired by MINIX 3 and Zircon. ARM64 and RISC-V.
Capabilities-based security. WebAssembly userspace.

## Progress

- [x] Rung 1: Toolchain and Boot
- [x] Rung 2: Exception Handling
- [x] Rung 3: MMU and Abstraction Layer
- [x] Rung 4: Timer and Clock Services
- [x] Rung 5: Device Tree Parsing
- [x] Rung 6: Physical Memory Allocator
- [x] Rung 7: Kernel Object Allocator
- [ ] Rung 8: Task Structures and Scheduler
- [ ] Rung 9: Per-Task Virtual Memory
- [ ] Rung 10: Symmetric Multiprocessing
- [ ] Rung 11: Tickless Scheduling
- [ ] Rung 12-24: Capability System
- [ ] Rung 25-28: Userspace Services
- [ ] Rung 29-31: WASM Runtime

---

## Phase 1: Foundation

### Rung 1: Toolchain and Boot

**Implement:** Cross-compilation for both architectures, UART output, boot
banner, HAL interface definitions.

**Questions:**

- HAL interface design before or during implementation?
- Boot protocol differences between architectures?

**Research:**

- RISC-V Privileged Spec: boot sequence
- ARM Reference Manual: boot and UART sections

### Rung 2: Exception Handling

**Implement:** Trap handlers for both architectures, register dumps, kernel
debug output (printf, panic).

**Questions:**

- Which registers to save in trap frame?
- Nested exception handling?

**Research:**

- OSTEP Chapter 6 (Limited Direct Execution)
- ARM64 Procedure Call Standard
- RISC-V Calling Convention

### Rung 3: MMU and Abstraction Layer

**Implement:** Paging with identity mapping, higher-half kernel, HAL for
architecture-specific MMU code.

**Questions:**

- Page table format differences between architectures?
- When to remove identity mapping?

**Research:**

- OSTEP Chapters 14-20 (Virtual Memory)
- RISC-V Sv48 specification
- ARM64 four-level page table specification

### Rung 4: Timer and Clock Services

**Implement:** Timer interrupts, monotonic clock syscalls, tick handlers for
preemptive scheduling foundation.

**Questions:**

- Timer frequency discovery: DTB vs hardware registers?
- Per-CPU vs global timer?

**Research:**

- OSDI3 Section 2.8 (The Clock Task in MINIX 3)
- RISC-V SBI timer specification
- ARM64 generic timer specification
- Zircon clock documentation

### Rung 5: Device Tree Parsing

**Implement:** libfdt integration, parse DTB for memory regions, interrupt
controller config (GIC/PLIC), peripheral addresses.

**Questions:**

- Which DTB properties are essential vs optional?
- Runtime vs compile-time hardware discovery?

**Research:**

- Devicetree Specification
- libfdt API documentation

### Rung 6: Physical Memory Allocator

**Implement:** Page allocator with leak detection. Research allocator strategies
(bitmap, buddy, free list).

**Questions:**

- Which allocator strategy for educational clarity?
- Per-page metadata vs external bitmap?

**Research:**

- OSDI3 Section 4.1 (basic memory management)
- Linux: buddy allocator
- xv6: kalloc

### Rung 7: Kernel Object Allocator

**Implement:** Slab or pool allocator for fixed-size kernel objects. Contiguous
page allocator for multi-page objects (stacks).

**Questions:**

- Slab vs pool vs simple bump allocator?
- Object caching benefits at this scale?

**Research:**

- Bonwick, "The Slab Allocator" (USENIX 1994)
- Linux: kmem_cache
- FreeBSD: UMA allocator

---

## Phase 2: Scheduling and SMP

### Rung 8: Task Structures and Scheduler

**Implement:** Task/thread data structures, per-arch register save sets, context
switch, round-robin scheduler, preemption via timer interrupts.

**Questions:**

- Which registers must be saved on context switch per architecture?
- Cooperative first, then preemptive? Or preemptive from start?
- Direct process switch optimization for IPC?

**Research:**

- OSTEP Chapter 4 (Process), Chapter 7 (Scheduling)
- OSDI3 Section 2.1 (processes), Section 2.4 (scheduling)
- xv6: struct proc, scheduler, swtch
- Linux: task_struct, CFS scheduler

### Rung 9: Per-Task Virtual Memory

**Implement:** Per-process address space, ASID management, address space
switching on context switch.

**Questions:**

- ASID allocation and recycling strategy?
- TLB flush on context switch vs ASID-tagged entries?

**Research:**

- OSTEP Chapters 14-20 (VM)
- OSDI3 Sections 4.3, 4.5, 4.7-4.8 (MINIX memory manager)
- ARM: ASID in TTBR0_EL1
- RISC-V: ASID in satp

### Rung 10: Symmetric Multiprocessing

**Implement:** Secondary CPU bringup, per-CPU stacks, per-CPU scheduler queues,
IPI for TLB shootdown.

**Questions:**

- Per-CPU data structures: static array or dynamic?
- Load balancing between CPUs?
- Which locks need to be SMP-aware?

**Research:**

- OSTEP Chapters 27-29 (Concurrency)
- ARM PSCI specification
- RISC-V SBI HSM extension
- Linux: per_cpu, smp_call_function

### Rung 11: Tickless Scheduling

**Implement:** Dynamic tick - timer fires only for actual deadlines, not
periodic. Per-CPU timer management.

**Questions:**

- How to track next deadline per CPU?
- Idle CPU handling?

**Research:**

- Linux NO_HZ documentation
- LWN "Tickless kernel" articles

---

## Phase 3: Capability System

### Rung 12: Kernel Object Model

**Implement:** Reference-counted kernel objects, common object header, destroy
on zero references.

**Questions:**

- Single object type enum or vtable-style dispatch?
- Object debugging/introspection?

**Research:**

- Zircon: kernel object lifecycle
- seL4: object types, capability spaces

### Rung 13: Handle Tables

**Implement:** Per-process handle table, handle as index + generation, rights
bitmap per entry.

**Questions:**

- Fixed-size or growable handle table?
- Handle generation to detect use-after-close?

**Research:**

- Zircon: handle table implementation
- OSDI3 Section 5.6.7 (file descriptors as model)

### Rung 14: Rights and Validation

**Implement:** Rights checking in syscall paths, rights per-handle not
per-object.

**Questions:**

- Which rights for each object type?
- Rights validation: per-syscall or centralized?

**Research:**

- Zircon: rights documentation
- OSDI3 Section 5.5 (protection)

### Rung 15: Derivation and Revocation

**Implement:** Handle derivation with attenuation (can only remove rights).

**Questions:**

- Revocation model: seL4 CDT tree or Zircon flat?
- Revocation granularity?

**Research:**

- seL4: capability derivation tree (CDT)
- capDL specification
- Zircon: handle duplication

### Rung 16: Memory Objects (VMO)

**Implement:** VMO for physical memory representation, mapping into address
spaces.

**Questions:**

- Lazy allocation vs eager?
- Page fault handling flow?

**Research:**

- Zircon: VMO documentation
- OSTEP Chapter 19 (TLBs), Chapter 21 (Beyond Physical Memory)

### Rung 17: Address Space Management (VMAR)

**Implement:** Virtual memory address regions, mapping VMOs into process address
space.

**Questions:**

- Hierarchical regions or flat?
- Guard pages?

**Research:**

- Zircon: VMAR documentation
- seL4: VSpace management

### Rung 18: Synchronous IPC

**Implement:** Synchronous message passing, send/receive/call primitives.

**Questions:**

- Message size limits?
- Register-based vs memory-based messages?
- Blocking semantics and timeouts?

**Research:**

- Liedtke SOSP 1993 (Improving IPC by Kernel Design)
- Liedtke SOSP 1995 (On µ-Kernel Construction)
- OSDI3 Section 2.2 (MINIX message passing)
- seL4: endpoint objects

### Rung 19: Handle Transfer

**Implement:** Move handles between processes via IPC.

**Questions:**

- Move vs copy semantics?
- Atomic transfer guarantees?

**Research:**

- Zircon: channel handle transfer
- seL4: capability transfer

### Rung 20: Async Notifications

**Implement:** Lightweight async signaling without full IPC.

**Questions:**

- Signal bits vs counters?
- Edge vs level triggered?

**Research:**

- seL4: Notification objects
- Zircon: signals, futex

### Rung 21: Fault Handling

**Implement:** Deliver faults to userspace via IPC.

**Questions:**

- Fault types to expose?
- Resume vs terminate semantics?

**Research:**

- Zircon: exception channels
- seL4: fault endpoints

### Rung 22: Hardware IRQ Objects

**Implement:** Bind hardware interrupts to notifications, userspace drivers.

**Questions:**

- IRQ masking/unmasking protocol?
- Shared interrupts?

**Research:**

- OSTEP Chapter 36 (I/O devices)
- OSDI3 Sections 2.6.8, 3.4.1 (MINIX interrupts)
- seL4: IRQHandler capability
- ARM GIC, RISC-V PLIC specs

### Rung 23: Memory Sharing

**Implement:** VMO sharing via handle duplication.

**Questions:**

- Copy-on-write clones?
- Shared vs private mappings?

**Research:**

- Zircon: VMO clone
- OSTEP Chapter 16 (Segmentation)

### Rung 24: Process Creation

**Implement:** Spawn syscall, explicit capability passing.

**Questions:**

- Minimal capability set for new process?
- ELF loading: kernel or userspace?

**Research:**

- Zircon: process_create, process_start
- "A fork() in the road" (HotOS 2019)
- seL4: process bootstrap

---

## Phase 4: Userspace Services

### Rung 25: Initial Bootstrap

**Implement:** Kernel creates init with bootstrap capabilities (root job, vDSO,
boot image).

**Questions:**

- What goes in vDSO?
- Bootstrap channel protocol?

**Research:**

- Zircon: userboot
- seL4: BootInfo structure

### Rung 26: Process Manager

**Implement:** Userspace process lifecycle server.

**Questions:**

- Capability-based process naming (no PIDs)?
- Process hierarchy or flat?

**Research:**

- OSDI3 Sections 4.7-4.8 (MINIX PM)
- Zircon: job/process hierarchy

### Rung 27: Device Manager

**Implement:** Device enumeration, distribute IRQ and MMIO capabilities to
drivers. UART as first userspace driver.

**Questions:**

- Driver isolation model?
- Hot-plug support?

**Research:**

- OSDI3 Section 3.5 (Block Devices in MINIX 3)
- Zircon: driver framework
- Linux: device model

### Rung 28: Filesystem Server

**Implement:** Simple ramfs, direct channel to filesystem per-app.

**Questions:**

- Protocol design (9P-inspired)?
- Namespace per-process?

**Research:**

- OSDI3 Sections 5.6-5.7 (MINIX FS)
- Plan 9: 9P protocol
- Zircon: fdio

---

## Phase 5: WASM Runtime

### Rung 29-31: WASM Integration

**Implement:** WASM interpreter process, WASI syscall layer, hello world
end-to-end.

**Questions:**

- Which WASM runtime to embed?
- WASI capability mapping to microkernel handles?

**Research:**

- WebAssembly specification
- WASI specification
- wasm3, wazero, wasmer (runtime options)

---

## Phase 6: Future

Network stack, virtio drivers, real filesystems, hardware testing (Pi 5, Orange
RV2).

---

## References

See [references.md](references.md) for full bibliography.
