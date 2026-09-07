# Code Style

Bullfinch is Rust code first. Keep code explicit, small, and reviewable.

## Baseline

- Use Rust 2024, `#![no_std]`, and `panic = "abort"` for kernel code.
- Use `core` by default. Add `alloc` only when allocator initialization makes it
  sound.
- Run `just lint` before handing off kernel or tool changes.

## Rust API Rules

- Prefer ownership, borrowing, guards, and `Drop` over raw handles.
- Prefer newtypes for addresses, page counts, IDs, rights, ticks, frequencies,
  and deadlines.
- Use `Locked<T>` for mutable global kernel state once normal locking is
  available. Keep raw `UnsafeCell` for early boot or architecture-local state
  with a local safety proof.
- Prefer `Option` for absence and `Result` for recoverable caller errors.
- Panic only for violated kernel invariants.
- Use `debug_assert!` for internal consistency after validation. Do not use it
  as the only check for userspace, firmware, or device input.
- Keep unsafe implementation details module-private where practical.
- Expose a safe API only when it is sound for every safe caller.
- Keep architecture-specific code under `arch/{aarch64,riscv64}`. Portable
  modules should consume architecture-neutral types.

## Assertions

Use three levels of checking:

- `Result`: external input, caller mistakes, and recoverable failures. Examples:
  malformed DTB data, bad user pointers, invalid handles, and MMIO ranges from
  firmware.
- `assert!` or `panic!`: kernel invariants that must hold in release builds.
  Examples: double-free, corrupted allocator metadata, impossible scheduler
  state, and stack teardown failures before returning pages to PMM.
- `debug_assert!` and `debug_assert_eq!`: internal consistency checks that
  depend on runtime state and should follow from earlier validation. Examples:
  ownership-transfer identity, FP status transitions, queue counters, and
  handle generation math.

A debug assertion checks assumptions during development. Release security
must not depend on it because release builds omit the check.

Prefer build-time or link-time assertions for static facts such as structure
layout, linker section ordering, page alignment, and constant bounds. Use a
runtime debug assertion only when the property cannot be checked before boot.

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
/// ABI. The caller must keep the target stack mapped.
pub unsafe fn switch_context(old: &mut Context, new: &Context);
```

Use `// SAFETY:` immediately before each unsafe block or unsafe impl:

```rust
// SAFETY: `ptr` comes from a mapped MMIO register and is used only with a
// volatile access.
unsafe { core::ptr::write_volatile(ptr, value) };
```

The comment must explain why the exact operation is valid. Name the invariant,
earlier check, or hardware rule that proves it. Saying only "this is safe"
does not provide that proof.

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

## Explanations And Documentation

Assume the reader knows Rust but may be new to kernel internals. Explain the
mechanism needed to understand the code, including why an algorithm or hardware
constraint affects this implementation. Define an unfamiliar concept where it
first matters. Use a small example when it makes the behavior easier to follow.

- Give each sentence one main point. Split long sentences at independent
  conditions or obligations, without losing their relationship.
- Name who acts or owns the state: the caller, scheduler, CPU, or lock holder.
- Put a prerequisite before the action that depends on it.
- Keep terminology consistent. Preserve technical distinctions between actions
  such as validating input and guaranteeing exclusive access.
- Keep requirements, recommendations, possibilities, and future plans distinct.
  Do not strengthen a recommendation or present a plan as current behavior.
- Preserve identifiers, commands, units, spec references, and safety conditions.
  A shorter sentence is useful only if it retains the same meaning.

Use short sentences as a guide, not a word-count requirement. Keep useful
headings, lists, and Rustdoc sections. Local notes can remain fragments.

Put explanations where the reader needs them. Module docs introduce the
mechanism; type docs describe ownership and invariants; function docs state
caller obligations and observable behavior. Local comments explain a choice
or ordering constraint at the affected code. Link to the defining type,
function, or specification section when more detail lives elsewhere. Keep the
local explanation sufficient to follow the code without opening the link.

Remove comments that only repeat a name, operation, or assertion message.
Keep local safety proofs even when they refer to a documented invariant.
Place future-work notes outside those proofs so planned behavior cannot be
mistaken for a condition that already holds.

These guidelines apply to documentation, explanatory comments, and decision
records in `docs/decisions.md`. When editing a decision record for style,
preserve the choice, alternatives, rationale, tradeoffs, and decision status.
Keep a change to the decision itself separate from a wording change.
