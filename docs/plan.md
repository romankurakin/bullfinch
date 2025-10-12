# Bullfinch OS Development Plan

Architecture: ARM64 and RISC-V with hardware abstraction layer

Kernel Type:  MINIX-style microkernel, small kernel with user space services.

Capability Model: Zircon-inspired capabilities system (simplified for educational use, seL4 ideas might be referenced).

User Programs: WebAssembly (WASM) runtime, WASI for applications. No POSIX compatibility layer.

Development Environment: Cross-compile from host. Use QEMU for initial testing, then real hardware (e.g., Raspberry Pi 5, Orange RV2).

Goal: Educational OS project for my own learning, not production use.

Named after the bullfinch, a northern bird that flourishes in harsh conditions — a symbol of resilience and grace.

---

## Implementation Phases

### Phase 1: Foundation

#### **Rung 0-1: Toolchain and Boot**

Set up cross-compilation for both architectures. Implement UART output and boot banner. Read RISC-V Privileged Spec and ARMv8 Reference Manual sections on boot and UART only.

#### Rung 2: Exception Handling

Implement trap handlers for both architectures with register dumps. Read architecture-specific exception handling chapters and OSTEP Chapter 6.

#### Rung 3: MMU and Abstraction Layer

Enable paging with identity mapping. Introduce hardware abstraction layer isolating architecture-specific code for MMU, interrupts, and timers. Read OSTEP Chapters 13, 18-20 and architecture paging specifications (Sv39 for RISC-V, four-level tables for ARM64).

#### Rung 4: Timer Interrupts

Implement 10ms tick on both architectures. Read timer specifications (SBI for RISC-V, generic timer for ARM64).

### Phase 2: Memory and Scheduling

#### Rung 5: Physical Memory Allocator

Implement bitmap-based page allocator with leak detection. Read OSTEP Chapters 18-20 on free space management and OSDI3 Section 4.1 on basic memory management.

#### Rung 6: Task Scheduler

Build round-robin scheduler with context switching. Read OSTEP Chapter 7, OSDI3 Sections 2.1 (process concepts) and 2.4 (scheduling algorithms).

#### Rung 7: Per-Task Virtual Memory

Implement address space isolation with ASID support. Read OSTEP Chapters 13, 18-20, OSDI3 Sections 4.3 (virtual memory), 4.5 (paging system design), 4.7-4.8 (MINIX 3 memory manager).

### Phase 3: Capability System and Core Kernel Objects

#### Rung 8: Basic Handle Tables

Implement per-process handle table with dynamic growth. Start with small number of slots, double when full up to certain maximum. Reallocation preserves handle numbers by copying to larger array. Read OSDI3 Section 5.3.4 (file descriptor tables in MINIX) and Zircon handle table implementation.

#### Rung 9: Rights and Validation

Add rights bitmaps to handle entries. Implement validation checks in syscall entry points. Return access errors when rights insufficient. Read OSDI3 Section 5.5 (protection mechanisms) and Zircon rights documentation.

#### Rung 10: Derivation and Revocation

Build handle derivation allowing attenuated copies. Track parent-child relationships for revocation. Implement recursive invalidation on close. Read seL4 manual on derivation and capDL paper for modeling.

#### Rung 11: Memory Objects (VMOs)

Implement VMO kernel object tracking physical pages. Support mapping into address spaces, direct read/write access, and rights enforcement. Replace direct page manipulation with VMO-based memory management. Read Zircon VMO documentation.

#### Rung 12: Synchronous IPC (Endpoints)

Build synchronous IPC with 64-byte fast path. Implement request-reply pattern where sender blocks until receiver processes message and sends reply. Use direct register transfer for small payloads. Read Liedtke SOSP 1993 and SOSP 1995 papers, OSDI3 Section 2.2 (MINIX message passing).

#### Rung 13: Handle Transfer

Extend IPC to transfer handles between processes. Implement handle moving from sender to receiver table. Enable capability delegation across address spaces. Read Zircon channel documentation on handle rights during transfer.

#### Rung 14: Async Notifications

Implement a **Notification** kernel object for asynchronous signaling. It will support two primary operations: `signal(badge)` and `wait()`. When a signal is sent, its 64-bit badge is bitwise OR'd into the object's internal state. A thread calling `wait()` will block until the state is non-zero, at which point it consumes the accumulated badge value and returns, resetting the state. This allows a single thread to efficiently monitor multiple event sources. Reference: seL4 manual (Notification objects) and Zircon documentation (Port objects).

#### Rung 15: Hardware IRQ Objects

Implement IRQ capabilities binding hardware interrupt lines to notification objects. Kernel ISR masks interrupt line, sets notification bit to wake waiting driver. Add syscalls: for setup and to signal completion and unmask line. Masking happens automatically in ISR, unmasking in ack handler. Test by routing timer interrupts through notification path before moving to userspace drivers. Read OSTEP Chapter 36 (I/O devices and interrupt handling), OSDI3 Section 5.4 (MINIX interrupt delivery to userspace), seL4 manual on IRQHandler/Notification binding, and architecture interrupt controller specs (RISC-V PLIC, ARM GIC).

#### Rung 16: Memory Sharing

Build VMO sharing between processes through handle duplication. Implement reference counting for shared VMOs. Optional: add copy-on-write support for efficient cloning. Combine with handle transfer for IPC-based memory sharing. Read OSTEP Chapter 21 (COW mechanisms), Zircon VMO clone semantics, and OSDI3 Section 4.2 (swapping) for shared page management.

### Phase 4: Core Services in Userspace

TBD

### Phase 5:  User Programs, WASM/WASI

TBD

---

## Reading References

### Core Operating Systems

OSTEP — <https://pages.cs.wisc.edu/~remzi/OSTEP>

OSDI3 — Operating Systems: Design & Implementation, 3rd ed. (Tanenbaum/Woodhull)

Plan9 Papers — <https://plan9.io/wiki/plan9/papers/index.html>

Operating System development tutorials in Rust on the Raspberry Pi — <https://github.com/rust-embedded/rust-raspberrypi-OS-tutorials>

### RISC-V Architecture

RISC-V Privileged Specification <https://github.com/riscv/riscv-isa-manual/releases/latest/download/riscv-privileged.pdf>

RISC-V SBI Specification <https://github.com/riscv-non-isa/riscv-sbi-doc/releases/latest/download/riscv-sbi.pdf>

#### ARM64 Architecture

ARM Architecture Reference Manual (DDI 0487) <https://developer.arm.com/documentation/ddi0487/latest/>

ARM GIC Specification (IHI 0069) <https://developer.arm.com/documentation/ihi0069/latest/>

#### Capability Systems

Zircon Kernel Documentation — <https://fuchsia.dev/fuchsia-src/concepts/kernel>

Zircon Kernel Objects — <https://fuchsia.dev/fuchsia-src/reference/kernel_objects/objects>

Zircon Rights — <https://fuchsia.dev/fuchsia-src/concepts/kernel/rights>

seL4 Reference Manual (derivation and revocation only) — <https://sel4.systems/Learn>

capDL Paper — <https://docs.sel4.systems/projects/capdl/>

#### Microkernel IPC

Liedtke SOSP 1993 — Improving IPC by Kernel Design

Liedtke SOSP 1995 — On µ-Kernel Construction

#### WASI and WebAssembly

WASM Specification — <https://webassembly.github.io/spec>

WASI Specification — <https://wasi.dev/resources>  

#### Device Drivers and Virtualization

QEMU virtio drivers — <https://git.qemu.org>
