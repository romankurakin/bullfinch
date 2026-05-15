# Testing

## Commands

```bash
just test                 # Unit tests on the host.
just test-filter "name"   # Run tests matching a filter.
just hooks                # Run prek hooks.
just lint                 # Clippy for tools, host kernel, and both targets.
just smoke                # QEMU boot tests for both architectures.
just smoke-arm64          # QEMU boot tests for ARM64.
just smoke-riscv64        # QEMU boot tests for RISC-V.
just host                 # Show host tool and smoke support.
just peek                 # Brief QEMU boot output for both architectures.
```

## Structure

Portable kernel modules use Rust unit tests and run through `just test`.
Architecture and hardware paths are validated by `just smoke`, which boots
ARM64 and RISC-V in QEMU in debug and release mode.

`bullfinch-tools` checks the host before smoke runs. It verifies the Rust
target, required QEMU binary, and raw-image support for boards that need
`llvm-objcopy`; unsupported combinations fail before building.

## Naming

Use the `"Subject behavior"` pattern:

- `"translate handles 1GB block mappings"`

## Review Checklist

- Good signal-to-noise ratio?
- Success and error paths covered?
- Works on both ARM64 and RISC-V?
