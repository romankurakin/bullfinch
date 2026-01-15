---
name: os-reference-search
description: Search OS reference materials — architecture specs (ARM, RISC-V), books (OSTEP, OSDI3), and papers. Use when implementing OS features (scheduler, IPC, VMM, drivers), looking up register layouts, finding algorithm details, or verifying chapter/section references in comments.
allowed-tools: AskUserQuestion, Bash, Read
---

# OS Reference Search Skill

Search architecture specs and OS books. The cache is in project root `.cache/`
(not the skill directory). Files are extracted `.txt` from PDFs via `pdftotext`.

## When to Use

- **Implementing features**: Look up scheduler algorithms in OSTEP, IPC in OSDI3
- **Hardware programming**: Find register layouts, bit fields, sequences in ARM/RISC-V manuals
- **Design decisions**: See how MINIX implements PM, FS, drivers
- **Verifying references**: Check chapter/section numbers before adding to comments

## Available Documents

**Architecture:**

- `DDI0487_profile_architecture_reference_manual.txt` — ARM Architecture Reference Manual
- `gic_architecture_specification.txt` — ARM GIC Specification
- `riscv-privileged.txt` — RISC-V Privileged Specification
- `riscv-unprivileged.txt` — RISC-V Unprivileged Specification
- `riscv-sbi.txt` — RISC-V SBI Specification
- `riscv-plic.txt` — RISC-V PLIC Specification

**Books:**

- `ostep.txt` — Operating Systems: Three Easy Pieces (OSTEP)
- `osdi3.txt` — Operating Systems: Design & Implementation (MINIX book)

## Search Patterns

All paths are relative to project root. Use `rg` from project root directory.

```bash
# Search ARM manual
rg -i "pattern" .cache/DDI0487_profile_architecture_reference_manual.txt | head -20

# Find ARM section titles (D-prefixed chapters for AArch64)
rg "^D[0-9]+\.[0-9]+" .cache/DDI0487_profile_architecture_reference_manual.txt | head -30

# Search RISC-V privileged spec
rg -i "pattern" .cache/riscv-privileged.txt

# Find RISC-V privileged chapter titles
rg "^Chapter [0-9]+" .cache/riscv-privileged.txt | head -20

# Search RISC-V unprivileged spec
rg -i "pattern" .cache/riscv-unprivileged.txt

# Search OSTEP (chapters are like "4 The Abstraction")
rg "^[0-9]+ [A-Z]" .cache/ostep.txt | head -50

# Search OSDI3 (sections are like "2.1 INTRODUCTION")
rg "^[0-9]+\.[0-9]+ [A-Z]" .cache/osdi3.txt | head -50
```

## Cache Management

Cache lives in project root `.cache/` (not skill directory). If empty or missing
files, ask the user for the PDF directory and generate from project root:

```bash
mkdir -p .cache
for f in /path/to/pdfs/*.pdf; do
  pdftotext "$f" .cache/"$(basename "$f" .pdf).txt"
done
```

## Reference Style

When citing specs in code comments, use the project's format:

- `See ARM Architecture Reference Manual, D1.4 (Exceptions).`
- `See RISC-V Privileged Specification, Chapter 12 (Supervisor-Level ISA).`
- `See RISC-V Unprivileged Specification, Chapter 2 (RV32I Base Integer).`
- `See OSTEP Chapter 6 (Limited Direct Execution).`
- `See OSDI3 Section 2.8 (The Clock Task).`
