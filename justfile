# Justfile for building and running the Bullfinch
default:
    @just --list

# Build for ARM64
build-arm64:
    zig build -Dtarget=aarch64-freestanding

# Build for RISC-V
build-riscv64:
    zig build -Dtarget=riscv64-freestanding

# Run in QEMU (ARM64) - binary format passes DTB pointer in x0
qemu-arm64: build-arm64
    llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    qemu-system-aarch64 -machine virt -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin

# Run in QEMU (RISC-V)
qemu-riscv64: build-riscv64
    qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64

# Smoke test ARM64 - build and run briefly to check boot
smoke-arm64: build-arm64
    llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    bash -c 'output=$(qemu-system-aarch64 -machine virt,gic-version=3 -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin 2>&1 & pid=$!; sleep 5; kill $pid; wait $pid 2>/dev/null); echo "$output"'

# Smoke test RISC-V - build and run briefly to check boot
smoke-riscv64: build-riscv64
    bash -c 'output=$(qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64 2>&1 & pid=$!; sleep 3; kill $pid; wait $pid 2>/dev/null); echo "$output"'

# Format code
fmt:
    zig fmt src

# Run tests
test:
    zig build test

# Run tests with filter
test-filter FILTER:
    zig build test -Dtest-filter="{{FILTER}}"

# Run specific test file
test-file FILE:
    zig test {{FILE}}

# Run tests for ARM64 architecture
test-arm64:
    zig build test -Dtarget=aarch64-freestanding

# Run tests for RISC-V architecture
test-riscv64:
    zig build test -Dtarget=riscv64-freestanding

# Build for ARM64 (release)
build-arm64-release:
    zig build -Dtarget=aarch64-freestanding -Doptimize=ReleaseFast

# Build for RISC-V (release)
build-riscv64-release:
    zig build -Dtarget=riscv64-freestanding -Doptimize=ReleaseFast

# Run in QEMU (ARM64, release)
qemu-arm64-release: build-arm64-release
    llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    qemu-system-aarch64 -machine virt -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin

# Run in QEMU (RISC-V, release)
qemu-riscv64-release: build-riscv64-release
    qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64

# Smoke test ARM64 (release)
smoke-arm64-release: build-arm64-release
    llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    bash -c 'output=$(qemu-system-aarch64 -machine virt,gic-version=3 -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin 2>&1 & pid=$!; sleep 5; kill $pid; wait $pid 2>/dev/null); echo "$output"'

# Smoke test RISC-V (release)
smoke-riscv64-release: build-riscv64-release
    bash -c 'output=$(qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64 2>&1 & pid=$!; sleep 3; kill $pid; wait $pid 2>/dev/null); echo "$output"'

# Disassemble kernel (ARM64)
disasm-arm64: build-arm64
    llvm-objdump -d --mattr=+all zig-out/bin/kernel-arm64

# Disassemble kernel (RISC-V)
disasm-riscv64: build-riscv64
    llvm-objdump -d -M no-aliases zig-out/bin/kernel-riscv64
