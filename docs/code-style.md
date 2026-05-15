# Code Style

Bullfinch is Rust code first. Keep code explicit, small, and reviewable.

## Baseline

- Use Rust 2024, `#![no_std]`, and `panic = "abort"` for kernel code.
- Use `core` by default. Add `alloc` only when allocator initialization makes it
  sound.
- Keep FP/SIMD disabled or unused until save/restore support exists.
- Run `just lint` before handing off kernel or tool changes.

Kernel crate attributes:

```rust
#![no_std]
#![deny(clippy::undocumented_unsafe_blocks)]
#![deny(unsafe_op_in_unsafe_fn)]
#![deny(unused_must_use)]
```

## Rust API Rules

- Prefer ownership, borrowing, guards, and `Drop` over raw handles.
- Prefer newtypes for addresses, page counts, IDs, rights, ticks, frequencies,
  and deadlines.
- Prefer `Option` for absence and `Result` for recoverable caller errors.
- Panic only for violated kernel invariants.
- Keep unsafe implementation details module-private where practical.
- Expose a safe API only when it is sound for every safe caller.
- Keep architecture-specific code under `arch/{aarch64,riscv64}`. Portable
  modules should consume architecture-neutral types.

## Modules

- Use normal Rust modules: `mod.rs` for multi-file modules and `foo.rs` for
  small single-file modules.
- Use `#[path = "..."]` only at target-selection boundaries.
- Keep binary-only boot and runtime code outside reusable model modules.
- Re-export only items that are part of the public module API.

## Unsafe Code

Rust `unsafe` has two roles:

- `unsafe fn`, `unsafe trait`, and `unsafe extern` define obligations that
  callers or implementers must uphold.
- `unsafe { ... }` and `unsafe impl` assert that those obligations have been
  checked at that site.

Rules:

- Keep unsafe blocks as small as practical.
- Even inside `unsafe fn`, wrap unsafe operations in explicit `unsafe` blocks.
- Use privacy to protect invariants relied on by unsafe code.
- Keep unsafe visible. Do not hide caller obligations behind a safe function
  unless the function is sound for every safe caller.
- Do not create Rust references to MMIO registers. Use raw pointers and
  volatile operations.
- Do not convert integers into references until ownership, alignment, validity,
  and aliasing are proven.
- Rust atomics do not replace ARM64 `DSB`/`ISB`, RISC-V `fence`, or TLB
  maintenance instructions.

## Safety Comments

Use Rustdoc `# Safety` sections for unsafe APIs:

```rust
/// Switches from one saved CPU context to another.
///
/// # Safety
///
/// The caller must ensure both contexts are valid for the architecture switch
/// ABI and that the target stack remains mapped.
pub unsafe fn switch_context(old: &mut Context, new: &Context);
```

Use `// SAFETY:` immediately before each unsafe block or unsafe impl:

```rust
// SAFETY: `ptr` comes from a mapped MMIO register and is used only with a
// volatile access.
unsafe { core::ptr::write_volatile(ptr, value) };
```

The comment must prove the exact operation. Good safety comments name the
invariant, the earlier check, or the hardware rule that makes the operation
valid. They should not say only "this is safe".

## Layout And Assembly

- Use `#[repr(C)]` for data shared with assembly, C ABI, or firmware.
- Use `#[repr(transparent)]` for integer and pointer newtypes.
- Avoid `#[repr(packed)]` for active kernel data.
- Add compile-time size/alignment/offset assertions for hardware-visible
  layout.
- Keep boot and trap assembly small. Call Rust once stack, ABI, and register
  state are valid.

## Naming

- Modules and functions: `snake_case`.
- Types and traits: `UpperCamelCase`.
- Constants and statics: `SCREAMING_SNAKE_CASE`.
- Constructors: `new`, `from_*`, or `try_from_*`.
- Prefer clear names over abbreviations in kernel APIs.
- Avoid acronym shouting in Rust type names: use `Asid`, `Tlb`, `Vmo`, `Vmar`,
  `Ipc`.

## General Comments

Use plain English and light punctuation.

- `///` and `//!` comments: complete sentences with terminal punctuation.
- `//` comments: fragments are fine for local notes.

Always document safety reasoning, architecture quirks, spec references, lock
ownership, memory ordering, barrier requirements, and non-obvious invariants.
Do not document obvious code or Rust basics.
