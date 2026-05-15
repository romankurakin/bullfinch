# Bullfinch

Educational microkernel in Rust for ARM64 and RISC-V, inspired by MINIX 3 and
Zircon. Built for clarity, correctness, and learning.

## Quick Start

```bash
just build-arm64      # or build-riscv64
just qemu-arm64       # or qemu-riscv64
just smoke            # smoke test both architectures
just host             # show host tool and smoke support
just hooks            # run prek hooks
just test             # run host unit tests
just lint             # run Clippy across tools and kernel targets
```

## Requirements

- Rust toolchain with Cargo, rustfmt, and Clippy
- Rust targets: `aarch64-unknown-none-softfloat`,
  `riscv64gc-unknown-none-elf`
- just
- prek
- QEMU
- LLVM tools

## Layout

- `rust/kernel/` contains the freestanding kernel crate.
- `tools/xtask/` contains the Rust developer tooling used by `just`.
- `docs/` contains design notes, style rules, test guidance, and references.

## License

MIT
