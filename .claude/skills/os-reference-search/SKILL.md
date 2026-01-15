---
name: os-reference-search
description: Search OS reference materials — architecture specs (ARM, RISC-V), books (OSTEP, OSDI3), and papers. Use when implementing OS features (scheduler, IPC, VMM, drivers), looking up register layouts, finding algorithm details, or verifying chapter/section references in comments.
allowed-tools: AskUserQuestion, Bash, Read
---

# OS Reference Search Skill

Search architecture specs and OS books. The user keeps source PDFs externally;
`.cache/` contains extracted `.txt` files (via `pdftotext`) for fast searching.

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

```bash
# Search ARM manual
rg -i "pattern" .cache/DDI0487_profile_architecture_reference_manual.txt | head -20

# Find ARM chapter titles
rg "^Chapter D[0-9]+" .cache/DDI0487_profile_architecture_reference_manual.txt

# Search specific ARM section
rg "D1\.7|D8\.[0-9]+" .cache/DDI0487_profile_architecture_reference_manual.txt

# Search RISC-V privileged spec
rg -i "pattern" .cache/riscv-privileged.txt

# Search OSTEP (chapters are like "4 The Abstraction")
rg "^[0-9]+ [A-Z]" .cache/ostep.txt | head -50

# Search OSDI3 (sections are like "2.1 INTRODUCTION")
rg "^[0-9]+\.[0-9]+ [A-Z]" .cache/osdi3.txt | head -50

# Verify a chapter reference exists
rg "^4\.7.*PROCESS MANAGER" .cache/osdi3.txt
```

## Cache Management

If `.cache/` is empty or missing files, ask the user for the PDF directory and
generate all caches:

```bash
mkdir -p .cache
for f in /path/to/pdfs/*.pdf; do
  pdftotext "$f" .cache/"$(basename "$f" .pdf).txt"
done
```

## Reference Style

When citing specs in code comments, use the project's format:

- `See ARM Architecture Reference Manual, D1.4 (Exceptions).`
- `See RISC-V Privileged Specification, Chapter 4 (Supervisor-Level ISA).`
- `See OSTEP Chapter 6 (Limited Direct Execution).`
- `See OSDI3 Section 2.8 (The Clock Task).`
