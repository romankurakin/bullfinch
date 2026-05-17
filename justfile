# Justfile for building and testing Bullfinch.

default:
    @just --list

clippy := "cargo clippy"
quiet := "--quiet"
warnings := "-- -D warnings"

build-arm64:
    @cargo run {{quiet}} -p bullfinch-tools -- build arm64 debug

build-riscv64:
    @cargo run {{quiet}} -p bullfinch-tools -- build riscv64 debug

build-arm64-release:
    @cargo run {{quiet}} -p bullfinch-tools -- build arm64 release

build-riscv64-release:
    @cargo run {{quiet}} -p bullfinch-tools -- build riscv64 release

host:
    @cargo run {{quiet}} -p bullfinch-tools -- host

qemu-arm64:
    @cargo run {{quiet}} -p bullfinch-tools -- qemu arm64 debug

qemu-riscv64:
    @cargo run {{quiet}} -p bullfinch-tools -- qemu riscv64 debug

qemu-arm64-release:
    @cargo run {{quiet}} -p bullfinch-tools -- qemu arm64 release

qemu-riscv64-release:
    @cargo run {{quiet}} -p bullfinch-tools -- qemu riscv64 release

test:
    @cargo test {{quiet}} -p bullfinch-kernel --lib

test-filter FILTER:
    @cargo test {{quiet}} -p bullfinch-kernel --lib "{{FILTER}}"

hooks:
    @prek validate-config prek.toml
    @prek run -c prek.toml --all-files

hooks-pre-commit:
    @prek validate-config prek.toml
    @prek run -c prek.toml --hook-stage pre-commit --all-files

hooks-install:
    @prek install -c prek.toml --hook-type pre-commit
    @prek install -c prek.toml --hook-type pre-push

lint: _lint-tools _lint-kernel (_lint-target "aarch64-unknown-none-softfloat") (_lint-target "riscv64gc-unknown-none-elf")

_lint-tools:
    @{{clippy}} {{quiet}} -p bullfinch-tools {{warnings}}

_lint-kernel:
    @{{clippy}} {{quiet}} -p bullfinch-kernel --lib {{warnings}}

_lint-target target:
    @{{clippy}} {{quiet}} -p bullfinch-kernel --target {{target}} --bin kernel {{warnings}}

smoke:
    @cargo run {{quiet}} -p bullfinch-tools -- smoke

smoke-arm64:
    @cargo run {{quiet}} -p bullfinch-tools -- smoke arm64

smoke-riscv64:
    @cargo run {{quiet}} -p bullfinch-tools -- smoke riscv64

peek:
    @cargo run {{quiet}} -p bullfinch-tools -- peek

peek-arm64:
    @cargo run {{quiet}} -p bullfinch-tools -- peek arm64

peek-riscv64:
    @cargo run {{quiet}} -p bullfinch-tools -- peek riscv64

fmt:
    @cargo fmt {{quiet}} --all

fmt-check:
    @cargo fmt {{quiet}} --all --check

disasm-arm64:
    @cargo run {{quiet}} -p bullfinch-tools -- disasm arm64 debug

disasm-riscv64:
    @cargo run {{quiet}} -p bullfinch-tools -- disasm riscv64 debug

clean:
    @cargo run {{quiet}} -p bullfinch-tools -- clean
