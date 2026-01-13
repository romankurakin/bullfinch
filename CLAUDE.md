# CLAUDE.md

Bullfinch is an educational microkernel inspired by MINIX 3 and Zircon, designed
to prioritize clarity, correctness, and comprehension over raw performance.
ARM64 and RISC-V architectures are supported, with a focus on modularity and
safety through capabilities.

## Commands

```bash
just build-arm64          # Build for ARM64
just build-riscv64        # Build for RISC-V

just qemu-arm64           # Run in QEMU (ARM64, interactive)
just qemu-riscv64         # Run in QEMU (RISC-V, interactive)

just peek-arm64           # Boot briefly, show console output
just peek-riscv64         # Boot briefly, show console output

just smoke                # Smoke test both architectures (pass/fail)
just smoke-one arm64      # Smoke test single architecture

just fmt                  # Format code
just test                 # Run all tests
just test-filter "name"   # Run tests matching filter
just test-arm64
just test-riscv64

just disasm-arm64         # Disassemble kernel (ARM64)
just disasm-riscv64       # Disassemble kernel (RISC-V)
```

## Build System

Single `build.zig` orchestrates the entire system:

1. **Kernel** — Freestanding executable for target architecture
2. **Userspace** — Each program compiled as separate executable (may have own build.zig)
3. **Packaging** — Userspace assembled into initramfs (simple file archive)
4. **Boards** — `-Dboard=<name>` selects board-specific files from `src/kernel/arch/{arm64,riscv64}/boards/{board}/`

The `qemu-*` commands automatically package and run kernel + initramfs.

## Code Style

Run `zig fmt` automatically (no permission needed).

### Naming

| Category  | Convention         | Examples                            |
| --------- | ------------------ | ----------------------------------- |
| Types     | `TitleCase`        | PageTable, HandleEntry, VmoObject   |
| Functions | `camelCase`        | mapPage, createHandle, scheduleNext |
| Variables | `snake_case`       | page_size, current_task             |
| Constants | `UPPER_SNAKE_CASE` | PAGE_SIZE, MAX_HANDLES              |

### Zig Patterns

- `const` by default, `var` only when mutation needed
- Explicit error handling: `try` propagates, `catch` handles
- No hidden allocations: pass `Allocator` parameter explicitly
- Use `defer` for cleanup (free memory, unlock, close)
- Prefer `?T` (optional) over `undefined` for "may not exist"
- Use `comptime` for generics and compile-time validation
- Mark kernel entry points with `export`
- Inline assembly for arch ops: `asm volatile (...)`

### Project Conventions

- Use `@panic()` for unrecoverable kernel errors
- Keep arch-specific code in `src/kernel/arch/{arm64,riscv64}/`
- Use HAL abstractions for portable kernel code
- Group panic messages in a `panic_msg` struct at module top:

```zig
const panic_msg = struct {
    const ALREADY_INITIALIZED = "PMM: already initialized";
    const NOT_INITIALIZED = "PMM: not initialized";
    const DOUBLE_FREE = "PMM: double-free detected";
};
```

### Comment Tags

Use these prefixes for special comments:

| Tag                | Usage                                                                      |
| ------------------ | -------------------------------------------------------------------------- |
| `// TODO(scope):`  | Mark incomplete functionality or planned improvements                      |

```zig

// TODO(pmm): Multi-region support - currently only uses first region.
if (!found_memory) {
```

### Comments

**Always document:** safety reasoning, architecture quirks, spec refs,
non-obvious "why", tricky bits

**Never document:** obvious "what", Zig basics, self-explanatory code

```zig
//! MMU operations for ARM64 - handles page mapping and TLB synchronization.

/// Unmaps a page and synchronizes the TLB.
pub fn unmapPage(vaddr: usize) void {
    pte.* = 0;
    // ARM requires DSB -> TLBI -> DSB -> ISB barrier sequence to guarantee all cores
    // observe the page table write before executing code that might depend
    // on the old mapping. Missing any part can cause security vulnerabilities.
    asm volatile ("dsb ish");
    asm volatile ("tlbi vale1is, %[addr]" :: [addr] "r" (vaddr >> 12));
    asm volatile ("dsb ish");
    asm volatile ("isb");
}
```

## Commits

Follow Conventional Commits: `<type>(<scope>): <subject>`

**Types:** feat, fix, perf, refactor, docs, test, build, chore, ci

**Scopes:** boot, mem, mmu, cap, arm64, riscv, arch, kernel, hal, ci, build

**Format:** Subject line + blank line + 3-4 sentence body explaining what and
why. Use prose, not bullet points.

```text
feat(mmu): implement virtual memory with higher-half kernel mapping

Add MMU support for both architectures using Sv48 (RISC-V) and 39-bit
VA (ARM64) with 4KB pages. Boot sequence identity-maps kernel at physical
address, enables paging, jumps to higher-half virtual address, then
removes identity mapping. Implement modular HAL that wires arch, board,
and common modules without circular dependencies.
```

## Safety Checklist

- [ ] No `undefined` without justification
- [ ] All errors handled (no `catch unreachable`)
- [ ] All allocations have cleanup (`defer`)
- [ ] Page tables page-aligned
- [ ] TLB invalidation after page table changes
- [ ] Memory barriers where architecturally required
- [ ] Capability rights checked before operations
- [ ] Integer overflow checks on user input (`std.math.add`)
- [ ] User pointers validated before dereferencing
- [ ] Both ARM64 and RISC-V tested

## Critical Rules

### Never

- Use `undefined` without justification
- Ignore errors or use `catch unreachable` without proof
- Skip memory barriers (DSB/ISB on ARM64, fence on RISC-V)
- Trust userspace input
- Forget TLB ops after page table modifications
- Hold locks across blocking operations or syscall boundaries
- Use unbounded loops in kernel code (DoS risk)
- Assume pointer is valid because "it can't be null here"
- Copy data between kernel/userspace without size validation

### Always

- Use explicit allocators (no hidden allocations)
- Validate capability rights
- Use checked arithmetic for user values
- Test both architectures
- Think: "What if interrupt fires right here?"
- Document what locks protect what data
- Keep interrupt-disabled sections minimal

## Error Philosophy

**Kernel space:** Return errors for recoverable conditions (resource exhaustion,
user mistakes, transient failures). Use `@panic()` when kernel invariants are
violated, architectural requirements broken, or state corrupted. Users never
cause kernel panics.

**Userspace:** Errors are normal program flow. Process can crash/exit on
unrecoverable errors without affecting kernel or other processes.

## Architecture Review Points

- **Memory barriers** — Different per arch; check placement before hardware ops and TLB operations
- **Privilege** — Exception vector alignment, register save sets, privilege boundary enforcement
- **Hardware** — Interrupt controller config, timer access (firmware vs direct), MMU page table formats

## Testing

### Structure

```text
src/kernel/
├── test.zig              # Main root - imports all sub-roots
├── kernel.zig            # Module root - imports subsystems (clock, mmu, pmm, etc.)
└── arch/
    ├── arm64/
    │   ├── test.zig      # ARM64 root - imports ARM64 modules
    │   └── uart.zig      # Contains inline tests
    └── riscv64/
        └── test.zig      # RISC-V root - imports RISC-V modules
```

**Inline tests (preferred):** Tests live in the same file as implementation.

**Root import system:** `test.zig` imports arch test roots and `kernel.zig`.
Modules must be in this import chain for their tests to run.

### Test Naming

Use descriptive names following `"subject behavior"` pattern:

| Pattern                     | Examples                                                   |
| --------------------------- | ---------------------------------------------------------- |
| `"Type.method behavior"`    | `"Pte.table creates valid table entry"`                    |
| `"function behavior"`       | `"translate handles 1GB block mappings"`                   |
| `"Type size and layout"`    | `"Pte size and layout"`, `"TrapContext size and layout"`   |
| `"CONSTANT is value"`       | `"PAGE_SIZE is 4KB"`                                       |

### Review Checklist

1. What scenarios are missing?
2. Does it test what I think it tests?
3. Are safety invariants validated?
4. Both success and error paths covered?
5. Works on ARM64 and RISC-V?

## References

- [Zig Documentation](https://ziglang.org/documentation/master)
- [OSTEP](https://pages.cs.wisc.edu/~remzi/OSTEP)
- [Fuchsia Kernel Concepts](https://fuchsia.dev/fuchsia-src/concepts/kernel)
- ARM and RISC-V official architecture documentation
