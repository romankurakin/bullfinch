---
name: os-reference-search
description: Search OS reference materials — architecture specs (ARM, RISC-V), books (OSTEP, OSDI3), and papers. Use when implementing OS features (scheduler, IPC, VMM, drivers), looking up register layouts, finding algorithm details, or verifying chapter/section references in comments.
allowed-tools: Bash, Read
---

# OS Reference Search Skill

Search architecture specs and OS books using the refs-cli tool at `../os-refs/`.

## When to Use

- **Implementing features**: Look up scheduler algorithms in OSTEP, IPC in OSDI3
- **Hardware programming**: Find register layouts, bit fields, sequences in ARM/RISC-V manuals
- **Design decisions**: See how MINIX implements PM, FS, drivers
- **Verifying references**: Check chapter/section numbers before adding to comments

## Search

```bash
cd ../os-refs

# Semantic search
uv run refs-cli.py -s "how to handle page faults"
uv run refs-cli.py -s "interrupt controller" -n 10

# Text search in extracted markdown
rg -i "TLB" *.md
```

Returns `file.md:start-end` with preview. Use Read tool for full context (add ~50 lines buffer for surrounding context).

## Available Documents

- `riscv-plic` — RISC-V PLIC Specification
- `riscv-sbi` — RISC-V SBI Specification
- `riscv-privileged` — RISC-V Privileged Specification
- `riscv-unprivileged` — RISC-V Unprivileged Specification
- `gic_architecture_specification` — ARM GIC Specification
- `ostep` — Operating Systems: Three Easy Pieces
- `osdi3` — Operating Systems: Design & Implementation (MINIX book)
- `DDI0487_profile_architecture_reference_manual` — ARM Architecture Reference Manual

## Setup

If `../os-refs/refs.db` is missing:

```bash
cd ../os-refs
uv run refs-cli.py --list              # Check status
uv run refs-cli.py --skip-topics       # Index (faster, no topics)
uv run refs-cli.py                     # Index with topics
```

## Reference Style

When citing in code comments:

```zig
// See ARM Architecture Reference Manual, D1.4 (Exceptions).
// See RISC-V Privileged Specification, 4.1.4 (Supervisor Scratch Register).
// See OSTEP Chapter 6 (Limited Direct Execution).
// See OSDI3 Section 2.8 (The Clock Task).
```
