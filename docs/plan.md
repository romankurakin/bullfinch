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
- [x] Rung 8: Task Structures and Scheduler
- [ ] Rung 9: Per-Task Virtual Memory
- [ ] Rung 10: Symmetric Multiprocessing
- [ ] Rung 11: Tickless Scheduling
- [ ] Rung 12: Handle Tables
- [ ] Rung 13: Rights and Validation
- [ ] Rung 14: Derivation and Revocation
- [ ] Rung 15: Memory Objects (VMO)
- [ ] Rung 16: Address Space Management (VMAR)
- [ ] Rung 17: Synchronous IPC
- [ ] Rung 18: Handle Transfer
- [ ] Rung 19: Async Notifications
- [ ] Rung 20: Fault Handling
- [ ] Rung 21: Hardware IRQ Objects
- [ ] Rung 22: Memory Sharing
- [ ] Rung 23: Process Creation
- [ ] Rung 24: Initial Bootstrap
- [ ] Rung 25: Process Manager
- [ ] Rung 26: Device Manager
- [ ] Rung 27: Filesystem Server
- [ ] Rung 28: WASM Integration

---

## Phase 1: Foundation

### Rung 1: Toolchain and Boot

**Implement:** Cross-compilation for both architectures, UART output, boot
banner, HAL interface definitions.

**Questions:**

- HAL interface design before or during implementation?
- Boot protocol differences between architectures?

**Research:**

- RISC-V Privileged Spec describes machine mode boot and hardware discovery
- ARM Reference Manual covers reset behavior and PL011 UART programming
- xv6: entry.S and start.c show minimal boot sequence for teaching
- Zircon: physboot handles early platform setup before kernel proper

### Rung 2: Exception Handling

**Implement:** Trap handlers for both architectures, register dumps, kernel
debug output (printf, panic).

**Questions:**

- Which registers to save in trap frame?
- Nested exception handling?

**Research:**

- OSTEP Chapter 6 explains trap-based system call and interrupt handling
- ARM64 Procedure Call Standard defines which registers are callee-saved
- RISC-V Calling Convention specifies register usage and stack layout
- xv6: trampoline.S and trap.c show clean exception entry and dispatch
- seL4: exception handling saves minimal state for fast IPC path

### Rung 3: MMU and Abstraction Layer

**Implement:** Paging with identity mapping, higher-half kernel, HAL for
architecture-specific MMU code.

**Questions:**

- Page table format differences between architectures?
- When to remove identity mapping?

**Research:**

- OSTEP Chapters 14-20 cover paging, TLBs, and address space concepts
- RISC-V Sv48 spec defines four-level page tables with 512 entries per level
- ARM64 spec describes TCR, TTBR registers and page descriptor formats
- xv6: vm.c has clean page table manipulation code for reference
- seL4: arch-specific MMU code shows how to abstract page table operations

### Rung 4: Timer and Clock Services

**Implement:** Timer interrupts, monotonic clock syscalls, tick handlers for
preemptive scheduling foundation.

**Questions:**

- Timer frequency discovery: DTB vs hardware registers?
- Per-CPU vs global timer?

**Research:**

- OSDI3 Section 2.8 describes MINIX clock task and alarm handling
- RISC-V SBI timer spec defines stimecmp and time CSR access
- ARM64 generic timer spec covers CNTFRQ, CNTP_CTL, and virtual timers
- Zircon: clock objects provide monotonic and boot time to userspace
- FreeBSD: kern_tc.c implements timecounter abstraction over hardware timers

### Rung 5: Device Tree Parsing

**Implement:** libfdt integration, parse DTB for memory regions, interrupt
controller config (GIC/PLIC), peripheral addresses.

**Questions:**

- Which DTB properties are essential vs optional?
- Runtime vs compile-time hardware discovery?

**Research:**

- Devicetree Specification defines node structure, properties, and bindings
- libfdt API provides functions for traversing and querying DTB blobs
- Linux: drivers/of/ shows mature DTB parsing and driver matching
- Zircon: board drivers parse DTB to configure platform-specific hardware
- FreeBSD: FDT support in sys/dev/fdt/ for BSD-style implementation

### Rung 6: Physical Memory Allocator

**Implement:** Page allocator with leak detection. Research allocator strategies
(bitmap, buddy, free list).

**Questions:**

- Which allocator strategy for educational clarity?
- Per-page metadata vs external bitmap?

**Research:**

- OSDI3 Section 4.1 (basic memory management)
- xv6: kalloc uses a simple free list suitable for teaching
- FreeBSD: vm_page and vm_phys for a clean BSD-style page allocator
- Linux: buddy allocator for efficient coalescing at scale

### Rung 7: Kernel Object Allocator

**Implement:** Slab or pool allocator for fixed-size kernel objects. Contiguous
page allocator for multi-page objects (stacks).

**Questions:**

- Slab vs pool vs simple bump allocator?
- Object caching benefits at this scale?

**Research:**

- Bonwick, "The Slab Allocator" (USENIX 1994) introduces object caching concepts
- FreeBSD: UMA allocator evolved from slab with per-CPU caches and NUMA awareness
- Linux: kmem_cache for comparison of a mature slab implementation

---

## Phase 2: Scheduling and SMP

### Rung 8: Task Structures and Scheduler

**Implement:** Thread and Process structs (minimal kernel-side), per-arch
register save sets, context switch, fair scheduler (weight-based vruntime),
preemption via timer interrupts.

**Questions:**

- Which registers must be saved on context switch per architecture?
- Cooperative first, then preemptive? Or preemptive from start?
- Direct process switch optimization for IPC?

**Research:**

- OSTEP Chapter 4 (Process), Chapter 7 (Scheduling)
- OSDI3 Section 2.1 (processes), Section 2.4 (scheduling)
- xv6: struct proc, struct context, swtch.S for minimal context switch
- MINIX: struct proc with priority queues, policy delegated to userspace
- Zircon: Thread as kernel object, fair scheduler with weighted fair queuing

### Rung 9: Per-Task Virtual Memory

**Implement:** Per-process address space, ASID management, address space
switching on context switch.

**Questions:**

- ASID allocation and recycling strategy?
- TLB flush on context switch vs ASID-tagged entries?

**Research:**

- OSTEP Chapters 14-20 (VM)
- OSDI3 Sections 4.3, 4.5, 4.7-4.8 (MINIX memory manager)
- Zircon: address space objects with explicit creation and destruction
- seL4: VSpace as a capability that can be delegated to userspace
- ARM: ASID field in TTBR0_EL1 for tagged TLB entries
- RISC-V: ASID field in satp register

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
- seL4: uses big-lock for tightly-coupled cores, multikernel for many-core
- FreeBSD: SMPng replaced giant lock with fine-grained locking over years
- Zircon: per-CPU structures and scheduler with work stealing between cores
- Linux: per_cpu macros and IPI mechanisms for cross-CPU coordination

### Rung 11: Tickless Scheduling

**Implement:** Dynamic tick - timer fires only for actual deadlines, not
periodic. Per-CPU timer management.

**Questions:**

- How to track next deadline per CPU?
- Idle CPU handling?

**Research:**

- FreeBSD: callout(9) moved from periodic ticks to one-shot with CalloutNG
- Zircon: timer slack allows coalescing nearby deadlines to reduce wakeups
- Linux: NO_HZ documentation explains the tickless kernel concepts

---

## Phase 3: Capability System

### Rung 12: Handle Tables

**Implement:** Per-process handle table, handle as index + generation, rights
bitmap per entry.

**Questions:**

- Fixed-size or growable handle table?
- Handle generation to detect use-after-close?

**Research:**

- Zircon: handle table uses generation numbers to detect stale handles
- seL4: CNode is a table of capabilities with explicit slot management
- OSDI3 Section 5.6.7 explains file descriptors as a simpler capability model

### Rung 13: Rights and Validation

**Implement:** Rights checking in syscall paths, rights per-handle not
per-object.

**Questions:**

- Which rights for each object type?
- Rights validation: per-syscall or centralized?

**Research:**

- Zircon: rights are a bitmask checked on every syscall that uses a handle
- seL4: capabilities encode both object reference and permitted operations
- OSDI3 Section 5.5 covers protection domains and access control concepts

### Rung 14: Derivation and Revocation

**Implement:** Handle derivation with attenuation (can only remove rights).

**Questions:**

- Revocation model: seL4 CDT tree or Zircon flat?
- Revocation granularity?

**Research:**

- seL4: capability derivation tree tracks parent-child for revocation
- capDL specification describes capability distribution at boot time
- Zircon: handle duplication is flat, no derivation tree, simpler revocation

### Rung 15: Memory Objects (VMO)

**Implement:** VMO for physical memory representation, mapping into address
spaces.

**Questions:**

- Lazy allocation vs eager?
- Page fault handling flow?

**Research:**

- Zircon: VMO represents physical pages, can be mapped into multiple address spaces
- seL4: Frame capabilities represent physical memory, mapped via VSpace
- OSTEP Chapters 19 and 21 cover TLB management and demand paging concepts

### Rung 16: Address Space Management (VMAR)

**Implement:** Virtual memory address regions, mapping VMOs into process address
space.

**Questions:**

- Hierarchical regions or flat?
- Guard pages?

**Research:**

- Zircon: VMAR provides hierarchical regions with sub-allocation to children
- seL4: VSpace management requires explicit page table capability manipulation
- FreeBSD: vm_map for a traditional mmap-style flat address space model

### Rung 17: Synchronous IPC

**Implement:** Synchronous message passing, send/receive/call primitives.
Receive wakes on endpoint OR bound notification.

**Questions:**

- Message size limits?
- Register-based vs memory-based messages?
- Blocking semantics and timeouts?
- Return value format for message vs notification wake?

**Research:**

- Liedtke SOSP 1993 shows how register-based IPC achieves low latency
- Liedtke SOSP 1995 argues for minimal kernels with fast IPC as foundation
- OSDI3 Section 2.2 describes MINIX message passing with fixed-size messages
- seL4: endpoints are rendezvous objects where sender blocks until receiver ready
- Zircon: channels are bidirectional, buffered, and transfer handles

### Rung 18: Handle Transfer

**Implement:** Move handles between processes via IPC.

**Questions:**

- Move vs copy semantics?
- Atomic transfer guarantees?

**Research:**

- Zircon: channels can carry handles, transferred atomically with the message
- seL4: capability transfer copies cap to receiver's CNode during IPC
- MINIX: grants allow temporary memory sharing without full capability transfer

### Rung 19: Async Notifications

**Implement:** Lightweight async signaling without full IPC. Notification
binding to threads for multiplexed receive.

**Questions:**

- Signal bits vs counters?
- Edge vs level triggered?
- Bind/unbind syscall design?

**Research:**

- MINIX: notify() provides lightweight signaling separate from message passing
- seL4: Notification objects with thread binding for multiplexed receive
- Zircon: signals on kernel objects, event objects, and futex for userspace sync

### Rung 20: Fault Handling

**Implement:** Deliver faults to userspace via IPC.

**Questions:**

- Fault types to expose?
- Resume vs terminate semantics?

**Research:**

- Zircon: exception channels deliver faults as messages to a handler process
- seL4: fault endpoints let a supervisor receive and handle thread faults
- MINIX: faults in servers trigger reincarnation server recovery logic

### Rung 21: Hardware IRQ Objects

**Implement:** Bind hardware interrupts to notifications, userspace drivers.

**Questions:**

- IRQ masking/unmasking protocol?
- Shared interrupts?

**Research:**

- OSTEP Chapter 36 covers device I/O concepts and interrupt handling
- OSDI3 Sections 2.6.8 and 3.4.1 explain how MINIX routes interrupts to drivers
- seL4: IRQHandler capability grants exclusive control of an interrupt line
- Zircon: interrupts are kernel objects that can be bound to ports
- ARM GIC and RISC-V PLIC specs for hardware-level configuration

### Rung 22: Memory Sharing

**Implement:** VMO sharing via handle duplication.

**Questions:**

- Copy-on-write clones?
- Shared vs private mappings?

**Research:**

- Zircon: VMO clone creates copy-on-write child sharing pages with parent
- seL4: shared memory via mapping same Frame into multiple VSpaces
- MINIX: grants provide controlled memory sharing between processes
- OSTEP Chapter 16 covers segmentation but COW is discussed in fork() context

### Rung 23: Process Creation

**Implement:** Spawn syscall, explicit capability passing.

**Questions:**

- Minimal capability set for new process?
- ELF loading: kernel or userspace?

**Research:**

- Zircon: process_create allocates structures, process_start begins execution
- seL4: process bootstrap requires explicit capability setup by parent
- MINIX: fork/exec handled by PM server which manages process table
- "A fork() in the road" (HotOS 2019) argues against fork() for modern systems

---

## Phase 4: Userspace Services

### Rung 24: Initial Bootstrap

**Implement:** Kernel creates init with bootstrap capabilities (root job, vDSO,
boot image).

**Questions:**

- What goes in vDSO?
- Bootstrap channel protocol?

**Research:**

- Zircon: userboot receives a channel with handles, processargs protocol
- seL4: BootInfo structure passed to root task describes available resources
- MINIX: kernel starts PM and VFS which initialize before accepting requests

### Rung 25: Process Manager

**Implement:** Userspace process lifecycle server with Erlang-style supervision
tree. Root supervisor is kernel-restartable; all other supervisors are normal
processes watching their children via IPC.

**Questions:**

- Capability-based process naming (no PIDs)?
- Process hierarchy or flat?
- Restart strategies: one-for-one, one-for-all, rest-for-one?
- Supervisor state recovery after restart?
- OOM policy: which processes to kill under memory pressure?

**Design:**

- Kernel only special-cases root supervisor (PID 1 or flagged at boot)
- Root supervisor death → kernel restarts it directly (no IPC)
- All other supervision is userspace processes using normal IPC
- Supervisors can supervise other supervisors (tree structure)
- Scheduling policy can be adjusted by process manager via syscall (mechanism
  in kernel, policy in userspace)
- Exited threads become zombies; parent reclaims resources via wait()
- OOM handling: kernel notifies PM of memory pressure, PM decides policy

**Research:**

- OSDI3 Sections 4.7-4.8 describe MINIX PM design and implementation
- MINIX: PM server maintains mproc table and handles syscalls via messages
- Zircon: jobs form a hierarchy, processes belong to jobs for resource control
- Erlang/OTP: supervision trees with restart strategies (one_for_one, etc.)
- "Crash-Only Software" (Candea & Fox, 2003): design for restart, not shutdown
- xv6: zombie state and wait() for safe thread resource cleanup
- Linux: OOM killer selects victim based on memory usage and oom_score

### Rung 26: Device Manager

**Implement:** Device enumeration, distribute IRQ and MMIO capabilities to
drivers. UART as first userspace driver.

**Questions:**

- Driver isolation model?
- Hot-plug support?

**Research:**

- OSDI3 Section 3.5 explains how MINIX 3 structures block device drivers
- MINIX: reincarnation server monitors drivers and restarts them on failure
- Zircon: driver framework v2 uses FIDL for type-safe driver communication
- seL4: drivers run as user processes with capabilities restricting hardware access

### Rung 27: Filesystem Server

**Implement:** Simple ramfs, direct channel to filesystem per-app.

**Questions:**

- Protocol design (9P-inspired)?
- Namespace per-process?

**Research:**

- OSDI3 Sections 5.6-5.7 cover MINIX filesystem server architecture
- MINIX: VFS routes requests to actual filesystem servers like MFS
- Plan 9: 9P protocol lets each process have its own namespace view
- Zircon: fdio provides POSIX-like file operations over FIDL channels

---

## Phase 5: WASM Runtime

### Rung 28: WASM Integration

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
RV2), security hardening (shadow call stack).

---

## References

See [references.md](references.md) for full bibliography.
