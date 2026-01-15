# Commit Conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/) with
[Linux kernel patch format](https://www.kernel.org/doc/html/latest/process/submitting-patches.html#describe-your-changes):

- Subject: ~50 chars, max 72
- Body: wrap at 72 chars, explain what and why

## Scopes

Use kernel module names (`sync`, `pmm`, `mmu`, `hal`, `alloc`, `fdt`, etc.),
architecture names (`arm64`, `riscv`), or infrastructure (`ci`, `build`, `test`).

## Example

```text
feat(mmu): implement virtual memory with higher-half kernel mapping

Add MMU support for both architectures using Sv48 (RISC-V) and 39-bit
VA (ARM64) with 4KB pages. Boot sequence identity-maps kernel at
physical address, enables paging, jumps to higher-half virtual address,
then removes identity mapping.
```

## Boundaries

- No `Co-Authored-By` lines for AI assistants
- No bullet points in commit body — use prose
