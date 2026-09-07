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

`just test` runs unit tests for portable kernel logic on the host. These tests
do not execute the architecture assembly or access emulated hardware.

`just smoke` builds and boots ARM64 and RISC-V in QEMU in both debug and
release modes. Each run passes when its output contains `[BOOT:OK]`, the
kernel's boot-completion marker, and `[SCHED:OK]`. The latter confirms that two
kernel threads start with interrupts enabled and both make progress through
timer preemption without yielding. Each worker waits at most one second for
its peer at each step.

Smoke and peek builds enable the `smoke-test` Cargo feature. Normal build and
interactive QEMU commands omit these test workers. The workers retain their
stacks until QEMU stops because thread exit is not implemented yet. These
checks cover boot and kernel-thread preemption, not every hardware operation
or future userspace workload.

Before each QEMU run, `bullfinch-tools` checks the Rust target and required
QEMU binary. For boards that need a raw image, it also checks `llvm-objcopy`.
If the host cannot support a run, the command fails before building its kernel.

Smoke logs are saved under `target/bullfinch/tests/`, with one file per
architecture and build mode. If a run fails, inspect its log for the last boot
stage or fault report. `just peek` prints brief boot output for the same four
variants, but does not require `[BOOT:OK]` to pass.

## Naming

Use the `"Subject behavior"` pattern:

- `"translate handles 1GB block mappings"`

## Review Checklist

- Good signal-to-noise ratio?
- Success and error paths covered?
- Works on both ARM64 and RISC-V?
