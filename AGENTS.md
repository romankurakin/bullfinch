# Agent instructions for Bullfinch

Bullfinch is an educational microkernel inspired by MINIX 3 and Zircon.
Prioritizes **clarity and correctness** over raw performance. Supports ARM64
and RISC-V with capabilities-based security.

## Commands

```bash
just build-arm64          # Build for ARM64
just build-riscv64        # Build for RISC-V

just qemu-arm64           # Run in QEMU (ARM64, interactive)
just qemu-riscv64         # Run in QEMU (RISC-V, interactive)

just peek-arm64           # Boot briefly, show console output
just peek-riscv64         # Boot briefly, show console output

just test                 # Unit tests (portable, runs on host)
just test-filter "name"   # Run tests matching filter
just smoke                # Integration tests (QEMU, both archs)

just fmt                  # Format code
just disasm-arm64         # Disassemble kernel (ARM64)
just disasm-riscv64       # Disassemble kernel (RISC-V)
```

## Build System

Single `build.zig` orchestrates:

1. **Kernel** — Freestanding executable for target architecture
2. **Userspace** — Each program compiled as separate executable
3. **Packaging** — Userspace assembled into initramfs
4. **Boards** — `-Dboard=<name>` selects from `src/kernel/arch/{arm64,riscv64}/boards/{board}/`

## Critical Rules

### Never

- Use `undefined` without justification
- Ignore errors or use `catch unreachable` without proof
- Skip memory barriers (DSB/ISB on ARM64, fence on RISC-V)
- Trust userspace input
- Forget TLB ops after page table modifications
- Hold locks across blocking operations or syscall boundaries
- Use unbounded loops in kernel code (DoS risk)
- Copy data between kernel/userspace without size validation

### Always

- Use explicit allocators (no hidden allocations)
- Validate capability rights before operations
- Use checked arithmetic for user values (`std.math.add`)
- Test both ARM64 and RISC-V
- Think: "What if interrupt fires right here?"
- Document what locks protect what data

## Error Philosophy

| Response   | When                                      | Example                                       |
| ---------- | ----------------------------------------- | --------------------------------------------- |
| `@panic()` | Kernel invariant violated, can't continue | Arithmetic overflow, double-free              |
| `error`    | Caller mistake, they can recover          | Bad alignment, missing page table             |
| `null`     | Absence of value, not an error            | OOM, lookup miss                              |

## Architecture Notes

- **Memory barriers** — Different per arch; required before hardware ops and TLB operations
- **Privilege** — Exception vector alignment, register save sets, privilege boundary enforcement
- **Hardware** — Interrupt controller config, timer access, MMU page table formats

## Documentation

**Always read the relevant doc before performing a task** (e.g., read
`docs/commits.md` before committing, `docs/code-style.md` before writing code).

- Roadmap: `docs/plan.md`
- Design decisions: `docs/decisions.md`
- Code style: `docs/code-style.md`
- Testing structure: `docs/testing.md`
- Commit format: `docs/commits.md`
- References: `docs/references.md`

## Workflow

For non-trivial changes, use plan mode to explore the codebase and design the
approach before implementing. Run `just smoke` after changes to verify both
architectures boot correctly.

## Skills

Use `/os-reference-search` to search architecture specs (ARM, RISC-V) and OS
books (OSTEP, OSDI3). Use `/os-source-search` to look up implementation patterns
in Linux, xv6, seL4, MINIX3, Fuchsia/Zircon, or FreeBSD.
