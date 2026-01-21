# Testing

## Commands

```bash
just test                 # Unit tests (portable, host)
just test-filter "name"   # Filter by name
just smoke                # Integration (QEMU, both archs)
```

## Structure

Portable modules have inline `test` blocks run via `just test`. Non-portable
modules are tested via `just smoke` which boots in QEMU.

## Naming

Use `"Subject behavior"` pattern:

- `"PageTableEntry.table creates valid entry"`
- `"translate handles 1GB block mappings"`

## Review Checklist

- Good signal-to-noise ratio?
- Success and error paths covered?
- Works on both ARM64 and RISC-V?
