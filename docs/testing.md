# Testing

## Commands

```bash
just test                 # Unit tests on the host.
just test-filter "name"   # Run tests matching a filter.
just lint                 # Clippy for tools, host kernel, and both targets.
just smoke                # QEMU boot tests for both architectures.
just peek                 # Brief QEMU boot output for both architectures.
```

## Structure

Portable kernel modules use Rust unit tests and run through `just test`.
Architecture and hardware paths are validated by `just smoke`, which boots
ARM64 and RISC-V in QEMU in debug and release mode.

## Naming

Use the `"Subject behavior"` pattern:

- `"translate handles 1GB block mappings"`

## Review Checklist

- Good signal-to-noise ratio?
- Success and error paths covered?
- Works on both ARM64 and RISC-V?
