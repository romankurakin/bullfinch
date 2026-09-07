# Bullfinch

Educational microkernel in Rust for ARM64 and RISC-V, inspired by MINIX 3 and
Zircon. Built for clarity, correctness, and learning.

## Requirements

- Rust toolchain with Cargo, rustfmt, and Clippy
- Rust targets: `aarch64-unknown-none-softfloat`,
  `riscv64imac-unknown-none-elf`
- just
- prek
- QEMU
- LLVM tools

## Quick Start

From the repository root, show the host tools and supported QEMU targets:

```bash
just host
```

Build and boot ARM64 in QEMU:

```bash
just qemu-arm64
```

For RISC-V, use `just qemu-riscv64`. Both commands build the kernel before
starting QEMU. To build without booting, use `just build-arm64` or
`just build-riscv64`.

## Checks

```bash
just test             # Run host unit tests.
just lint             # Run Clippy across tools and kernel targets.
just smoke            # Test QEMU boot on both architectures.
just hooks            # Run the configured prek hooks.
```

Host tests check portable kernel logic. Smoke tests exercise boot and hardware
paths in QEMU. See [Testing](docs/testing.md) for coverage, logs, and commands
for each architecture.

## Layout

- `kernel/` contains the freestanding kernel crate.
- `tools/xtask/` contains the Rust developer tooling used by `just`.
- `docs/` contains design notes, style rules, test guidance, and references.

## License

MIT
