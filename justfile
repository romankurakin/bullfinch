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
run-arm64:
    zig build qemu-arm64 -Dtarget=aarch64-freestanding

# Run in QEMU (RISC-V)
run-riscv64:
    zig build qemu-riscv64 -Dtarget=riscv64-freestanding

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
