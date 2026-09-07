# Bullfinch Development Plan

Educational microkernel inspired by MINIX 3 and Zircon. ARM64 and RISC-V.
Capabilities-based security. WebAssembly userspace.

The checklist tracks completed stages. Each stage below records its scope and
research questions. Unchecked stages describe planned work, not current kernel
behavior. See [decisions.md](decisions.md) for accepted design choices.

## Progress

- [x] Rung 1: Toolchain and Boot
- [x] Rung 2: Exception Handling
- [x] Rung 3: MMU and Abstraction Layer
- [x] Rung 4: Timer and Clock Services
- [x] Rung 5: Device Tree Parsing
- [x] Rung 6: Physical Memory Allocator
- [x] Rung 7: Kernel Object Allocator
- [x] Rung 8: Task Structures and Scheduler
- [x] Rung 9: FP/SIMD State
- [ ] Rung 10: Per-Task Virtual Memory
- [ ] Rung 11: Symmetric Multiprocessing
- [ ] Rung 12: Tickless Scheduling
- [ ] Rung 13: Handle Tables
- [ ] Rung 14: Rights and Validation
- [ ] Rung 15: Derivation and Revocation
- [ ] Rung 16: Memory Objects (VMO)
- [ ] Rung 17: Address Space Management (VMAR)
- [ ] Rung 18: Synchronous IPC
- [ ] Rung 19: Handle Transfer
- [ ] Rung 20: Async Notifications
- [ ] Rung 21: Fault Handling
- [ ] Rung 22: Hardware IRQ Objects
- [ ] Rung 23: Memory Sharing
- [ ] Rung 24: Process Creation
- [ ] Rung 25: Initial Bootstrap
- [ ] Rung 26: Process Manager
- [ ] Rung 27: Device Manager
- [ ] Rung 28: Filesystem Server
- [ ] Rung 29: WASM Integration

---

## Phase 1: Foundation

### Rung 1: Toolchain and Boot

**Implement:** Cross-compile the kernel for both architectures. Add UART
output, a boot banner, and hardware abstraction layer (HAL) interfaces.

**Questions:**

- HAL interface design before or during implementation?
- Boot protocol differences between architectures?

**Research:**

- RISC-V Privileged Spec describes machine mode boot and hardware discovery
- ARM Reference Manual covers reset behavior and PL011 UART programming
- xv6: entry.S and start.c show minimal boot sequence for teaching
- Zircon: physboot handles early platform setup before kernel proper

### Rung 2: Exception Handling

**Implement:** Add trap handlers for both architectures. Include register
dumps and kernel diagnostic output through printf and panic.

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

**Implement:** Add paging with identity mappings, where virtual and physical
addresses are equal. Map the kernel into the higher half of virtual memory.
Expose architecture-specific MMU operations through the HAL.

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

**Implement:** Add timer interrupts and monotonic clock syscalls. Use timer
ticks as the basis for preemptive scheduling, where an interrupt can stop
the current thread.

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

**Implement:** Parse the device-tree blob (DTB) for memory regions,
interrupt-controller configuration (GIC/PLIC), and peripheral addresses.

**Questions:**

- Which DTB properties are essential vs optional?
- Runtime vs compile-time hardware discovery?

**Research:**

- Devicetree Specification defines node structure, properties, and bindings
- `google/dtoolkit` provides a `no_std`, no-alloc read-only FDT parser
- Linux: drivers/of/ shows mature DTB parsing and driver matching
- Zircon: board drivers parse DTB to configure platform-specific hardware
- FreeBSD: FDT support in sys/dev/fdt/ for BSD-style implementation

### Rung 6: Physical Memory Allocator

**Implement:** Add a physical page allocator with leak detection. Compare
bitmap, buddy, and free-list allocation strategies.

**Questions:**

- Which allocator strategy for educational clarity?
- Per-page metadata vs external bitmap?

**Research:**

- OSDI3 Section 4.1 (basic memory management)
- xv6: kalloc uses a simple free list suitable for teaching
- FreeBSD: vm_page and vm_phys for a clean BSD-style page allocator
- Linux: buddy allocator for efficient coalescing at scale

### Rung 7: Kernel Object Allocator

**Implement:** Add a slab or pool allocator for kernel objects of fixed
sizes. Add contiguous page allocation for objects that need several pages,
such as stacks.

**Questions:**

- Slab vs pool vs simple bump allocator?
- Object caching benefits at this scale?

**Research:**

- Bonwick, "The Slab Allocator" (USENIX 1994) introduces object caching concepts
- FreeBSD: UMA allocator evolved from slab with per-CPU caches and NUMA awareness
- Linux: kmem_cache for comparison of a mature slab implementation

---

## Phase 2: Scheduling, FP/SIMD, and SMP

### Rung 8: Task Structures and Scheduler

**Implement:** Add minimal kernel-side Thread and Process structures,
architecture register save sets, and context switching. Implement fair
scheduling with virtual runtime adjusted by thread weight. Use timer
interrupts for preemption.

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

### Rung 9: FP/SIMD State

**Implement:** Add user FP/SIMD state for ARM64 NEON/FP and RISC-V scalar
FP. Build the kernel for the soft-float targets
`aarch64-unknown-none-softfloat` and `riscv64imac-unknown-none-elf`.

Compiled kernel code does not use FP/SIMD registers. Trap entry disables
access while leaving user state in the registers. First use initializes the
thread's state. A thread switch saves outgoing state and restores incoming
state to transfer ownership. RISC-V can skip saves of clean state. SVE, SME,
and RVV are out of scope.

**Research:**

- ARM ARM and AAPCS64 for NEON/FP state
- RISC-V Privileged Spec and psABI for scalar FP state
- Zephyr ARM64 FP/SIMD sharing model

### Rung 10: Per-Task Virtual Memory

**Implement:** Give each process an address space. Manage address-space
identifiers (ASIDs) and switch address spaces during context switches.

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

### Rung 11: Symmetric Multiprocessing

**Implement:** Start secondary CPUs and give each CPU its own stack and
scheduler queue. Use interprocessor interrupts (IPIs) to request TLB
invalidation on other CPUs.

**Questions:**

- Per-CPU data structures: static array or dynamic?
- Load balancing between CPUs?
- Which locks need to be SMP-aware?
- Do measured FP-heavy workloads justify per-CPU lazy FP ownership and its
  cross-CPU migration protocol over eager transfer at each thread switch?

**Research:**

- OSTEP Chapters 27-29 (Concurrency)
- ARM PSCI specification
- RISC-V SBI HSM extension
- seL4: uses big-lock for tightly-coupled cores, multikernel for many-core
- FreeBSD: SMPng replaced giant lock with fine-grained locking over years
- Zircon: per-CPU structures and scheduler with work stealing between cores
- Linux: per_cpu macros and IPI mechanisms for cross-CPU coordination

### Rung 12: Tickless Scheduling

**Implement:** Program the timer for the next deadline instead of periodic
ticks. Manage deadlines separately for each CPU.

**Questions:**

- How to track next deadline per CPU?
- Idle CPU handling?

**Research:**

- FreeBSD: callout(9) moved from periodic ticks to one-shot with CalloutNG
- Zircon: timer slack allows coalescing nearby deadlines to reduce wakeups
- Linux: NO_HZ documentation explains the tickless kernel concepts

---

## Phase 3: Capability System

### Rung 13: Handle Tables

**Implement:** Add a handle table to each process. Represent each handle
with an index and generation, so a reused slot can be distinguished from an
old handle. Store a rights bitmap in each entry.

**Questions:**

- Fixed-size or growable handle table?
- Handle generation to detect use-after-close?

**Research:**

- Zircon: handle table uses generation numbers to detect stale handles
- seL4: CNode is a table of capabilities with explicit slot management
- OSDI3 Section 5.6.7 explains file descriptors as a simpler capability model

### Rung 14: Rights and Validation

**Implement:** Validate handle rights in syscall paths. Attach rights to
each handle, rather than to the shared object.

**Questions:**

- Which rights for each object type?
- Rights validation: per-syscall or centralized?

**Research:**

- Zircon: rights are a bitmask checked on every syscall that uses a handle
- seL4: capabilities encode both object reference and permitted operations
- OSDI3 Section 5.5 covers protection domains and access control concepts

### Rung 15: Derivation and Revocation

**Implement:** Derive handles with reduced rights. A derived handle can
remove rights but cannot add them.

**Questions:**

- Revocation model: seL4 CDT tree or Zircon flat?
- Revocation granularity?

**Research:**

- seL4: capability derivation tree tracks parent-child for revocation
- capDL specification describes capability distribution at boot time
- Zircon: handle duplication is flat, no derivation tree, simpler revocation

### Rung 16: Memory Objects (VMO)

**Implement:** Represent physical memory with virtual memory objects (VMOs).
Map these objects into address spaces.

**Questions:**

- Lazy allocation vs eager?
- Page fault handling flow?

**Research:**

- Zircon: VMO represents physical pages, can be mapped into multiple address spaces
- seL4: Frame capabilities represent physical memory, mapped via VSpace
- OSTEP Chapters 19 and 21 cover TLB management and demand paging concepts

### Rung 17: Address Space Management (VMAR)

**Implement:** Add virtual memory address regions (VMARs). Use them to
manage where VMOs map into a process address space.

**Questions:**

- Hierarchical regions or flat?
- Guard pages?

**Research:**

- Zircon: VMAR provides hierarchical regions with sub-allocation to children
- seL4: VSpace management requires explicit page table capability manipulation
- FreeBSD: vm_map for a traditional mmap-style flat address space model

### Rung 18: Synchronous IPC

**Implement:** Add synchronous message passing with send, receive, and call
operations. A receive must wake for either an endpoint message or a bound
notification. Use the same paired integer and FP ownership transfer for
blocking, yielding, and timer-driven trap switches.

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

### Rung 19: Handle Transfer

**Implement:** Move handles between processes through IPC.

**Questions:**

- Move vs copy semantics?
- Atomic transfer guarantees?

**Research:**

- Zircon: channels can carry handles, transferred atomically with the message
- seL4: capability transfer copies cap to receiver's CNode during IPC
- MINIX: grants allow temporary memory sharing without full capability transfer

### Rung 20: Async Notifications

**Implement:** Add lightweight asynchronous notifications. Bind a
notification to a thread so a receive can wait for either a message or a
notification.

**Questions:**

- Signal bits vs counters?
- Edge vs level triggered?
- Bind/unbind syscall design?

**Research:**

- MINIX: notify() provides lightweight signaling separate from message passing
- seL4: Notification objects with thread binding for multiplexed receive
- Zircon: signals on kernel objects, event objects, and futex for userspace sync

### Rung 21: Fault Handling

**Implement:** Deliver faults to userspace through IPC.

**Questions:**

- Fault types to expose?
- Resume vs terminate semantics?

**Research:**

- Zircon: exception channels deliver faults as messages to a handler process
- seL4: fault endpoints let a supervisor receive and handle thread faults
- MINIX: faults in servers trigger reincarnation server recovery logic

### Rung 22: Hardware IRQ Objects

**Implement:** Bind hardware interrupts to notifications for userspace
drivers.

**Questions:**

- IRQ masking/unmasking protocol?
- Shared interrupts?

**Research:**

- OSTEP Chapter 36 covers device I/O concepts and interrupt handling
- OSDI3 Sections 2.6.8 and 3.4.1 explain how MINIX routes interrupts to drivers
- seL4: IRQHandler capability grants exclusive control of an interrupt line
- Zircon: interrupts are kernel objects that can be bound to ports
- ARM GIC and RISC-V PLIC specs for hardware-level configuration

### Rung 23: Memory Sharing

**Implement:** Share VMOs by duplicating their handles.

**Questions:**

- Copy-on-write clones?
- Shared vs private mappings?

**Research:**

- Zircon: VMO clone creates copy-on-write child sharing pages with parent
- seL4: shared memory via mapping same Frame into multiple VSpaces
- MINIX: grants provide controlled memory sharing between processes
- OSTEP Chapter 16 covers segmentation but COW is discussed in fork() context

### Rung 24: Process Creation

**Implement:** Add a spawn syscall with explicit capability passing. Once
two user threads can run, test FP isolation between them on both
architectures.

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

### Rung 25: Initial Bootstrap

**Implement:** Have the kernel create init with bootstrap capabilities for
the root job, vDSO, and boot image.

**Questions:**

- What goes in vDSO?
- Bootstrap channel protocol?

**Research:**

- Zircon: userboot receives a channel with handles, processargs protocol
- seL4: BootInfo structure passed to root task describes available resources
- MINIX: kernel starts PM and VFS which initialize before accepting requests

### Rung 26: Process Manager

**Implement:** Add a userspace process manager with an Erlang-style
supervision tree. The kernel can restart the root supervisor. Other
supervisors are ordinary processes that monitor their children through IPC.

**Questions:**

- Capability-based process naming (no PIDs)?
- Process hierarchy or flat?
- Restart strategies: one-for-one, one-for-all, rest-for-one?
- Supervisor state recovery after restart?
- OOM policy: which processes to kill under memory pressure?

**Design:**

- Only the root supervisor has special kernel handling (PID 1 or a boot flag).
- If the root supervisor dies, the kernel restarts it directly without IPC.
- Other supervisors monitor children through ordinary userspace IPC.
- Supervisors can monitor other supervisors, forming a tree.
- The process manager selects scheduling policy through syscalls. The kernel
  provides the scheduling mechanism.
- Exited threads remain as zombies until the parent reclaims them with wait().
- When memory runs low, the kernel notifies the process manager. The process
  manager decides how to respond.

**Research:**

- OSDI3 Sections 4.7-4.8 describe MINIX PM design and implementation
- MINIX: PM server maintains mproc table and handles syscalls via messages
- Zircon: jobs form a hierarchy, processes belong to jobs for resource control
- Erlang/OTP: supervision trees with restart strategies (one_for_one, etc.)
- "Crash-Only Software" (Candea & Fox, 2003): design for restart, not shutdown
- xv6: zombie state and wait() for safe thread resource cleanup
- Linux: OOM killer selects victim based on memory usage and oom_score

### Rung 27: Device Discovery and Manager

**Implement:** Add userspace device discovery and a device manager. Keep
only the kernel interrupt-controller setup needed until userspace drivers
exist.

**Questions:**

- Driver isolation model?
- Hot-plug support?
- When should IRQ/MMIO objects become user-space capabilities?

**Research:**

- OSDI3 Section 3.5 explains how MINIX 3 structures block device drivers
- MINIX: reincarnation server monitors drivers and restarts them on failure
- Zircon: driver framework v2 uses FIDL for type-safe driver communication
- seL4: drivers run as user processes with capabilities restricting hardware access

### Rung 28: Filesystem Server

**Implement:** Add a simple RAM filesystem (ramfs). Give each application a
direct channel to the filesystem server.

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

### Rung 29: WASM Integration

**Implement:** Add a WebAssembly interpreter process and a WASI syscall
layer. Run a hello-world program through the complete path.

**Questions:**

- Which WASM runtime to embed?
- WASI capability mapping to microkernel handles?

**Research:**

- WebAssembly specification
- WASI specification
- wasm3, wazero, wasmer (runtime options)

---

## Phase 6: Future

Later work includes a network stack, virtio drivers, additional filesystems,
and hardware testing on Pi 5 and Orange RV2.

---

## References

See [references.md](references.md) for full bibliography.
