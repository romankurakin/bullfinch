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

just test                 # Unit tests on the host.
just test-filter "name"   # Run tests matching filter.
just lint                 # Clippy for tools and kernel targets.
just smoke                # QEMU smoke tests for both architectures.

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
