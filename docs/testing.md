# Testing

See [Zig Testing](https://ziglang.org/documentation/master/#Zig-Test) for
language fundamentals.

## Commands

```bash
just test                 # Unit tests (portable, runs on host)
just test-filter "name"   # Run tests matching filter
just smoke                # Integration tests (QEMU, both archs)
```

## Test Pyramid

```
┌─────────────┐
│   smoke     │  Integration: boots kernel in QEMU (ARM64 + RISC-V)
├─────────────┤
│   test      │  Unit tests: portable algorithms, data structures
└─────────────┘
```

## Structure

Portable modules (no hal/arch dependency) have inline `test` blocks that run
via `just test` on any host (macOS, Linux, x86, ARM):

- `sync/ticket.zig` — ticket lock algorithm
- `fdt/` — device tree parsing
- `lib/` — utilities

Non-portable modules (depend on hal/arch) are tested via `just smoke` which
boots the full kernel in QEMU.

## Naming

Use `"subject behavior"` pattern:

- `"Pte.table creates valid table entry"`
- `"translate handles 1GB block mappings"`
- `"PAGE_SIZE is 4KB"`

## Review Checklist

1. What scenarios are missing?
2. Both success and error paths covered?
3. Works on ARM64 and RISC-V?
