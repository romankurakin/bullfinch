# Testing

See [Zig Testing](https://ziglang.org/documentation/master/#Zig-Test) for
language fundamentals.

## Commands

```bash
just test                 # Run all tests
just test-filter "name"   # Run tests matching filter
just test-arm64           # ARM64 only
just test-riscv64         # RISC-V only
```

## Structure

Tests use inline `test` blocks in implementation files. Root imports:

- `src/kernel/test.zig` — imports `kernel.zig` and arch roots
- `src/kernel/arch/{arm64,riscv64}/test.zig` — arch-specific roots

Modules must be in this import chain for their tests to run.

`just test` runs on the host architecture only. Use `just smoke` to boot-test
both ARM64 and RISC-V in QEMU.

## Naming

Use `"subject behavior"` pattern:

- `"Pte.table creates valid table entry"`
- `"translate handles 1GB block mappings"`
- `"PAGE_SIZE is 4KB"`

## Review Checklist

1. What scenarios are missing?
2. Both success and error paths covered?
3. Works on ARM64 and RISC-V?
