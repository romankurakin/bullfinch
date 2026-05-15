# Agent Instructions For Bullfinch

Bullfinch is an educational Rust microkernel inspired by MINIX 3 and Zircon.
It prioritizes clarity and correctness over raw performance. It supports ARM64
and RISC-V with capabilities-based security.

## Commands

```bash
just build-arm64          # Build for ARM64.
just build-riscv64        # Build for RISC-V.

just qemu-arm64           # Run in QEMU (ARM64, interactive).
just qemu-riscv64         # Run in QEMU (RISC-V, interactive).

just peek                 # Boot both architectures briefly.
just peek-arm64           # Boot ARM64 briefly.
just peek-riscv64         # Boot RISC-V briefly.

just host                 # Show host tool and smoke support.
just hooks                # Run prek hooks.
just test                 # Unit tests on the host.
just test-filter "name"   # Run tests matching filter.
just lint                 # Clippy for tools and kernel targets.
just smoke                # QEMU smoke tests for both architectures.
just smoke-arm64          # QEMU smoke tests for ARM64.
just smoke-riscv64        # QEMU smoke tests for RISC-V.

just fmt                  # Format Rust code.
just disasm-arm64         # Disassemble kernel (ARM64).
just disasm-riscv64       # Disassemble kernel (RISC-V).
```

## Build System

Cargo builds the freestanding kernel crate. The `tools/xtask` Rust crate owns
developer commands for building, QEMU smoke tests, formatting, linting,
disassembly, and cleanup. `just` is a thin command runner over that Rust tool.

## Critical Rules

### Never

- Use `unsafe` without a local safety proof.
- Ignore errors where callers can recover.
- Skip memory barriers (`DSB`/`ISB` on ARM64, `fence` on RISC-V).
- Trust userspace, firmware, or device input.
- Forget TLB maintenance after page table modifications.
- Hold locks across blocking operations or syscall boundaries.
- Use unbounded loops in kernel code where userspace can control progress.
- Copy data between kernel and userspace without size validation.

### Always

- Prefer owned types and guards over raw handles.
- Validate capability rights before operations.
- Use checked arithmetic for user-controlled values.
- Test both ARM64 and RISC-V.
- Think: "What if an interrupt fires right here?"
- Document what locks protect what data.

## Error Philosophy

| Response | When | Example |
| --- | --- | --- |
| `panic!()` | Kernel invariant violated, cannot continue | Arithmetic overflow, double-free |
| `Result` | Caller mistake, caller can recover | Bad alignment, missing page table |
| `Option` | Absence of value, not an error | OOM, lookup miss |

## Target Hardware

| Platform | Architecture |
| --- | --- |
| QEMU virt | ARM64, RISC-V |
| Raspberry Pi 5 | ARM64 (ARMv8.2-A) |
| Orange Pi RV2 | RISC-V |
| Arduino UNO Q | ARM64 (ARMv8.0-A) |

## Architecture Notes

- **Memory barriers:** Different per architecture; required before hardware
  operations and TLB maintenance.
- **Privilege:** Exception vector alignment, register save sets, and privilege
  boundary enforcement are architecture-specific.
- **Hardware:** Interrupt controller setup, timer access, and MMU page table
  formats live behind architecture modules.

## Documentation

Always read the relevant doc before performing a task.

- Roadmap: `docs/plan.md`
- Design decisions: `docs/decisions.md`
- Code style: `docs/code-style.md`
- Testing structure: `docs/testing.md`
- Commit format: `docs/commits.md`
- References: `docs/references.md`
- Hardware specs: `docs/hardware.md`

## Workflow

For non-trivial changes, explore the codebase and design the approach before
editing. Run `just smoke` after architecture-sensitive changes.

## Skills

Use `/os-reference-search` to search architecture specs (ARM, RISC-V) and OS
books (OSTEP, OSDI3). Use `/os-source-search` to look up implementation
patterns in Linux, xv6, seL4, MINIX3, Fuchsia/Zircon, or FreeBSD.
