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
    @zig build -Dtarget=riscv64-freestanding -Dcpu=generic_rv64+zihintpause -Doptimize=ReleaseFast

# Run in QEMU

qemu-arm64: build-arm64
    @llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    @echo "qemu: arm64"
    @qemu-system-aarch64 -machine virt -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin

qemu-riscv64: build-riscv64
    @echo "qemu: riscv64"
    @qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64

qemu-arm64-release: build-arm64-release
    @llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    @echo "qemu: arm64 (release)"
    @qemu-system-aarch64 -machine virt -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin

qemu-riscv64-release: build-riscv64-release
    @echo "qemu: riscv64 (release)"
    @qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64

test:
    @echo "test: unit"
    @zig build test --summary all

test-filter FILTER:
    @echo "test: unit (filter={{FILTER}})"
    @zig build test --summary all -Dtest-filter="{{FILTER}}"

smoke: build-arm64 build-riscv64
    @llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    @echo "test: smoke"
    @zig build smoke

# Peek (brief boot, for debugging)

peek-arm64: build-arm64
    #!/usr/bin/env bash
    llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    output=$(qemu-system-aarch64 -machine virt,gic-version=3 -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin 2>&1 & pid=$!; sleep 2; kill $pid; wait $pid 2>/dev/null)
    echo "$output" | while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*#[0-9]+[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
            addr="${BASH_REMATCH[1]}"
            sym=$(llvm-symbolizer -e zig-out/bin/kernel-arm64 "$addr" 2>/dev/null | head -1)
            echo "$line  $sym"
        else
            echo "$line"
        fi
    done

peek-riscv64: build-riscv64
    #!/usr/bin/env bash
    output=$(qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64 2>&1 & pid=$!; sleep 2; kill $pid; wait $pid 2>/dev/null)
    echo "$output" | while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*#[0-9]+[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
            addr="${BASH_REMATCH[1]}"
            sym=$(llvm-symbolizer -e zig-out/bin/kernel-riscv64 "$addr" 2>/dev/null | head -1)
            echo "$line  $sym"
        else
            echo "$line"
        fi
    done

peek-arm64-release: build-arm64-release
    #!/usr/bin/env bash
    llvm-objcopy -O binary zig-out/bin/kernel-arm64 zig-out/bin/kernel-arm64.bin
    output=$(qemu-system-aarch64 -machine virt,gic-version=3 -cpu cortex-a76 -smp 2 -m 2G -nographic -kernel zig-out/bin/kernel-arm64.bin 2>&1 & pid=$!; sleep 2; kill $pid; wait $pid 2>/dev/null)
    echo "$output" | while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*#[0-9]+[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
            addr="${BASH_REMATCH[1]}"
            sym=$(llvm-symbolizer -e zig-out/bin/kernel-arm64 "$addr" 2>/dev/null | head -1)
            echo "$line  $sym"
        else
            echo "$line"
        fi
    done

peek-riscv64-release: build-riscv64-release
    #!/usr/bin/env bash
    output=$(qemu-system-riscv64 -machine virt -smp 2 -m 2G -nographic -bios default -kernel zig-out/bin/kernel-riscv64 2>&1 & pid=$!; sleep 2; kill $pid; wait $pid 2>/dev/null)
    echo "$output" | while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*#[0-9]+[[:space:]]+(0x[0-9a-fA-F]+) ]]; then
            addr="${BASH_REMATCH[1]}"
            sym=$(llvm-symbolizer -e zig-out/bin/kernel-riscv64 "$addr" 2>/dev/null | head -1)
            echo "$line  $sym"
        else
            echo "$line"
        fi
    done

# Tools

fmt:
    @echo "fmt: src/"
    @zig fmt src

disasm-arm64: build-arm64
    @llvm-objdump -d --mattr=+all zig-out/bin/kernel-arm64

disasm-riscv64: build-riscv64
    @llvm-objdump -d -M no-aliases zig-out/bin/kernel-riscv64
