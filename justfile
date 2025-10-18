# Justfile for building and running the Bullfinch
default:
    @just --list

# Build for ARM64
build-arm64:
    zig build -Dtarget=aarch64-freestanding

# Build for RISC-V
build-riscv64:
    zig build -Dtarget=riscv64-freestanding

# Run in QEMU (ARM64)
qemu-arm64: build-arm64
    qemu-system-aarch64 -machine virt -cpu cortex-a76 -m 128M -nographic -kernel zig-out/bin/kernel-arm64

# Run in QEMU (RISC-V)
qemu-riscv64: build-riscv64
    qemu-system-riscv64 -machine virt -m 128M -nographic -bios default -kernel zig-out/bin/kernel-riscv64

# Smoke test ARM64 - build and run briefly to check boot
smoke-arm64: build-arm64
    bash -c 'output=$(qemu-system-aarch64 -machine virt -cpu cortex-a76 -m 128M -nographic -kernel zig-out/bin/kernel-arm64 2>&1 & pid=$!; sleep 3; kill $pid; wait $pid 2>/dev/null); echo "$output"'

# Smoke test RISC-V - build and run briefly to check boot
smoke-riscv64: build-riscv64
    bash -c 'output=$(qemu-system-riscv64 -machine virt -m 128M -nographic -bios default -kernel zig-out/bin/kernel-riscv64 2>&1 & pid=$!; sleep 3; kill $pid; wait $pid 2>/dev/null); echo "$output"'

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

# Disassemble kernel (ARM64)
disasm-arm64: build-arm64
    llvm-objdump -d --mattr=+all zig-out/bin/kernel-arm64

# Disassemble kernel (RISC-V)
disasm-riscv64: build-riscv64
    llvm-objdump -d -M no-aliases zig-out/bin/kernel-riscv64
