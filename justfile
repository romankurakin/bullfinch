# Justfile for building and testing Bullfinch OS kernel

default:
    @just --list


build-arm64:
    @echo "build: arm64"
    @zig build -Dtarget=aarch64-freestanding -Dcpu=cortex_a76

build-riscv64:
    @echo "build: riscv64"
    @zig build -Dtarget=riscv64-freestanding

build-arm64-release:
    @echo "build: arm64 (release)"
    @zig build -Dtarget=aarch64-freestanding -Dcpu=cortex_a76 -Doptimize=ReleaseFast

build-riscv64-release:
    @echo "build: riscv64 (release)"
    @zig build -Dtarget=riscv64-freestanding -Doptimize=ReleaseFast

# Run in QEMU (uses boards.zig config)

qemu-arm64:
    @echo "qemu: arm64"
    @zig build run -Dtarget=aarch64-freestanding -Dcpu=cortex_a76

qemu-riscv64:
    @echo "qemu: riscv64"
    @zig build run -Dtarget=riscv64-freestanding

qemu-arm64-release:
    @echo "qemu: arm64 (release)"
    @zig build run -Dtarget=aarch64-freestanding -Dcpu=cortex_a76 -Doptimize=ReleaseFast

qemu-riscv64-release:
    @echo "qemu: riscv64 (release)"
    @zig build run -Dtarget=riscv64-freestanding -Doptimize=ReleaseFast

test:
    @echo "test: unit"
    @zig build test --summary all

test-filter FILTER:
    @echo "test: unit (filter={{FILTER}})"
    @zig build test --summary all -Dtest-filter="{{FILTER}}"

smoke ARGS="": build-arm64 build-arm64-release build-riscv64 build-riscv64-release
    @echo "test: smoke"
    @zig build smoke -- {{ARGS}}

peek: build-arm64 build-arm64-release build-riscv64 build-riscv64-release
    @echo "test: peek"
    @zig build smoke -- --peek

# Tools

fmt:
    @echo "fmt: src/"
    @zig fmt src

disasm-arm64: build-arm64
    @llvm-objdump -d --mattr=+all zig-out/kernel/arm64-qemu_virt-debug.elf

disasm-riscv64: build-riscv64
    @llvm-objdump -d -M no-aliases zig-out/kernel/riscv64-qemu_virt-debug.elf

clean:
    @rm -rf zig-out zig-cache
