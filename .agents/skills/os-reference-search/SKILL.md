---
name: os-reference-search
description: Search OS reference materials — architecture specs (ARM, RISC-V), books (OSTEP, OSDI3), and papers. Use when implementing OS features (scheduler, IPC, VMM, drivers), looking up register layouts, finding algorithm details, or verifying chapter/section references in comments.
---

# OS Reference Search Skill

Search architecture specs and OS books using globally installed `sova`.
Assumes `sova` is available in `PATH`.

## When to Use

- **Implementing features**: Look up scheduler algorithms in OSTEP, IPC in OSDI3
- **Hardware programming**: Find register layouts, bit fields, sequences in ARM/RISC-V manuals
- **Design decisions**: See how MINIX implements PM, FS, drivers
- **Verifying references**: Check chapter/section numbers before adding to comments

## Search

```bash
# Semantic search
sova -s "how to handle page faults"
sova -s "interrupt controller" -n 10

# Text search in extracted markdown
rg -i "TLB" ~/.sova/data/*.md
```

Returns `~/.../file.md:start-end` plus full chunk text. Use Read tool for extra
surrounding context (~50 lines buffer).

## Available Documents

- `arm_aapcs64` — Procedure Call Standard for the Arm 64-bit Architecture (AArch64)
- `arm_profile_architecture_reference_manual` — ARM Architecture Reference Manual
- `gic_architecture_specification` — ARM GIC Specification
- `macintosh_HIG_1992` — Macintosh Human Interface Guidelines (1992)
- `operating_systems_design_and_implementation` — Operating Systems: Design & Implementation (MINIX book)
- `operating_systems_three_easy_pieces` — Operating Systems: Three Easy Pieces (OSTEP book)
- `riscv-abi` — RISC-V ABIs Specification
- `riscv-plic` — RISC-V PLIC Specification
- `riscv-privileged` — RISC-V Privileged Specification
- `riscv-sbi` — RISC-V SBI Specification
- `riscv-unprivileged` — RISC-V Unprivileged Specification

## Setup

If `~/.sova/data/indexed.db` is missing:

```bash
sova --list       # Check status
sova              # Index all documents
```

## Reference Style

When citing in code comments:

```zig
// See ARM Architecture Reference Manual, D1.4 (Exceptions).
// See RISC-V Privileged Specification, 4.1.4 (Supervisor Scratch Register).
// See OSTEP Chapter 6 (Limited Direct Execution).
// See OSDI3 Section 2.8 (The Clock Task).
```
