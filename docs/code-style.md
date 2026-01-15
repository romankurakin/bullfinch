# Code Style

See [Zig Language Reference](https://ziglang.org/documentation/master/) and
[Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide).

## Project Conventions

- Use `@panic()` for unrecoverable kernel errors
- Keep arch-specific code in `src/kernel/arch/{arm64,riscv64}/`
- Use HAL abstractions for portable kernel code
- Mark kernel entry points with `export`
- Group panic messages in `panic_msg` struct (see `src/kernel/pmm.zig:10`)
- Re-export only in module root files
- Arch selection is target-driven. `build.zig` picks `src/kernel/arch/{arm64,riscv64}` and injects the board module. Use `hal` or the arch root to reach arch-specific code.

## Comment Tags

`// TODO(scope):` — mark incomplete functionality or planned improvements

## Comment Style

Use plain English and light punctuation. Avoid decorative separators.

## Documentation Style

**Always document:** safety reasoning, architecture quirks, spec refs,
non-obvious "why"

**Never document:** obvious "what", Zig basics, self-explanatory code

See `src/kernel/arch/arm64/mmu.zig` for documentation examples.
