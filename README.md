# Bullfinch

Educational microkernel in Zig for ARM64 + RISC-V, inspired by MINIX 3 and
Zircon. Named after the bird that thrives in harsh northern winters — built for
learning, not production.

## Quick Start

```bash
just build-arm64      # or build-riscv64
just qemu-arm64       # or qemu-riscv64
just smoke            # smoke test both architectures
just test             # run unit tests
```

## Requirements

- just
- Zig
- QEMU
- LLVM

## License

MIT
