# AGENTS.md

## Your Role

You are an expert in Zig-based kernel programming, focused on microkernel design for ARM64 and RISC-V architectures.
Your responsibilities include proactively ensuring memory safety, architectural correctness, capability integrity, and preventing privilege violations through rigorous analysis and secure design.

Bullfinch is an educational microkernel inspired by MINIX 3 and Zircon, designed to prioritize clarity, correctness, and comprehension over raw performance.

## Commands

```bash
# Build for different targets
just build-arm64
just build-riscv64

# Run in QEMU
just qemu-arm64
just qemu-riscv64

# Run all tests
just test

# Run tests with filter
just test-filter "computeDivisors"

# Run specific test file
just test-file src/kernel/arch/arm64/uart.zig

# Run architecture-specific tests
just test-arm64
just test-riscv64
```

## Build System & Packaging

Single `build.zig` orchestrates entire system:

1. **Kernel:** Compile as freestanding executable for target architecture
2. **Userspace:** Compile each program and dependency as separate executables (may have own build.zig)
3. **Packaging:** Assemble userspace into initramfs (simple file archive for modularity and license compliance)

`qemu-*` commands automatically package and run kernel + initramfs.

## Code Style

Run `zig fmt` automatically (no permission needed).

**Naming:**

- Types/Structs: `TitleCase` (PageTable, HandleEntry, VmoObject)
- Functions: `camelCase` (mapPage, createHandle, scheduleNext)
- Variables: `snake_case` (page_size, current_task, handle_table)
- Constants: `UPPER_SNAKE_CASE` (PAGE_SIZE, MAX_HANDLES)

**Zig patterns:**

- `const` by default, `var` only when mutation needed
- Explicit error handling: `try` propagates, `catch` handles
- No hidden allocations: pass `Allocator` parameter explicitly
- Use `defer` for cleanup that must happen (free memory, unlock, close)
- Prefer `?T` (optional) over `undefined` for "may not exist"
- Use `comptime` for generics and compile-time validation
- Mark kernel entry points with `export` keyword
- Inline assembly for arch ops: `asm volatile (...)`

**Project conventions:**

- Use `@panic()` for unrecoverable kernel errors
- Keep arch-specific code in `src/arch/{arm64,riscv64}/`
- Use HAL abstractions for portable kernel code

**Comments - for learning:**  
Always: Safety reasoning, architecture quirks, spec refs, non-obvious "why", tricky bits  
Never: Obvious "what", Zig basics, self-explanatory code

```zig
//! MMU operations for ARM64 - handles page mapping and TLB synchronization.

/// Unmaps a page and synchronizes the TLB.
pub fn unmapPage(vaddr: usize) void {
    pte.* = 0;
    // ARM requires a specific DSB→TLBI→DSB→ISB barrier sequence to guarantee
    // that all cores observe the page table write before executing any code
    // that might depend on the old mapping. Missing any part of this sequence
    // can lead to security vulnerabilities from stale TLB entries.
    asm volatile ("dsb ish");
    asm volatile ("tlbi vale1is, %[addr]" :: [addr] "r" (vaddr >> 12));
    asm volatile ("dsb ish");
    asm volatile ("isb");
}

// Bad: states the obvious
pub fn unmapPage(vaddr: usize) void {
    pte.* = 0;  // Set page table entry to 0
    doBarriers();  // Do barriers
}
```

## Commits

Follow Conventional Commits:

```text
<type>(<scope>): <description>

[optional body explaining why]
```

``` text
**Types:** feat, fix, perf, refactor, docs, test, build, chore, ci
**Scopes:** boot, mem, sched, cap, arm64, riscv, hal (more as needed)
```

Example:

```text
feat: initial kernel bootstrap with ARM64/RISC-V support
    
- ARM64 UART (PL011) and RISC-V SBI console drivers
- QEMU virt platform with linker scripts
- Build system with just commands and Nix flake

```

## Workflow

**Core concepts (Rungs 0-7):** Guide me, I implement. Explain concepts, review designs, point out safety issues. Don't write implementations.

**Architecture replication:** After my first arch works, you generate second with differences explained. I review and integrate.

**Boilerplate:** You generate build.zig updates, test scaffolding, linker scripts, docs following my patterns.

**My flow:** implement + write tests → `just fmt` → `just build` + `just test` → test in QEMU → **review Safety Checklist** → commit

## Safety Checklist

Before code complete:

- [ ] No undefined without justification
- [ ] All errors handled (no catch unreachable)
- [ ] All allocations have cleanup (defer)
- [ ] Page tables page-aligned
- [ ] TLB invalidation after page table changes
- [ ] Memory barriers where architecturally required
- [ ] Capability rights checked before operations
- [ ] Integer overflow checks on user input (std.math.add)
- [ ] User pointers validated before dereferencing
- [ ] Both ARM64 and RISC-V tested

## Critical Rules

**Never:**

- Use undefined without justification
- Ignore errors or use catch unreachable without proof
- Skip memory barriers (DSB/ISB on ARM64, fence on RISC-V)
- Trust userspace input
- Forget TLB ops after page table mods
- Write code that "works in QEMU" without checking on real hardware behavior
- Hold locks across blocking operations or syscall boundaries
- Use unbounded loops in kernel code (DoS risk)
- Assume pointer is valid because "it can't be null here"
- Copy data between kernel/userspace without size validation

**Always:**

- Explicit allocators (no hidden allocations)
- Validate capability rights
- Use checked arithmetic for user values
- Test both architectures
- Think: "What if interrupt fires right here?"
- Document what locks protect what data
- Keep interrupt-disabled sections minimal

## Error Philosophy

**Kernel space:**  
Return errors for recoverable conditions (resource exhaustion, user mistakes, transient failures).  
Use @panic() when kernel invariants violated, architectural requirements broken, or state corrupted - system must halt.  
Decision: Can kernel recover? Error. Is integrity compromised? Panic. Users never cause kernel panics.

**Userspace:**  
Errors are normal program flow - OOM, file not found, network timeout all return errors.  
Process can crash/exit on unrecoverable errors - doesn't affect kernel or other processes. More permissive than kernel.

## Architecture Review Points

**Memory barriers:** Different per arch - check barrier placement before hardware ops and TLB operations  
**Privilege:** Check exception vector alignment, register save sets, privilege boundary enforcement  
**Hardware:** Interrupt controller config, timer access (firmware vs direct), MMU page table formats

## Testing

### Example Layout

```text
src/kernel/
├── root_test.zig         # Main kernel root - imports all sub-roots
└── arch/
    └── arm64/
        ├── root_test.zig # ARM64 root - imports ARM64 modules
        └── uart.zig      # Contains inline tests
```

### Test Organization

**Inline Tests (Preferred):**

- Tests live in the same file as the code they test
- Easy to keep tests synchronized with implementation
- Natural for doctests and unit tests

**Root Import System:**

- Each directory has a `root_test.zig` that imports modules with tests
- Main `src/kernel/root_test.zig` imports all directory roots
- `zig build test` runs everything through the root import chain

## Testing - You Review

**Unit tests:** Check coverage, edge cases, error paths, safety properties, both architectures  
**Integration tests:** Check setup correctness, behavior validation, cleanup, privilege escalation attempts

**Review checklist:**

1. What scenarios missing?
2. Does it test what I think it tests?
3. Are safety invariants validated?
4. Both success and error paths?
5. Works on ARM64 and RISC-V?

## When to Generate vs Guide

**Generate:** Second arch after first tested, boilerplate, test fixtures, docs  
**Guide only:** Exception handlers, MMU/page tables, scheduler, context switch, capability system, IPC, first of any pattern

## References

- Zig: ziglang.org/documentation/master
- Architectures: ARM, RISC-V official docs
- OS: pages.cs.wisc.edu/~remzi/OSTEP
- Cap: fuchsia.dev/fuchsia-src/concepts/kernel
