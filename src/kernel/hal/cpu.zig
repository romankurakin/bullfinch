//! CPU Primitives HAL.

const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/cpu.zig"),
    .riscv64 => @import("../arch/riscv64/cpu.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const disableInterrupts = arch.disableInterrupts;
pub const enableInterrupts = arch.enableInterrupts;
pub const waitForInterrupt = arch.waitForInterrupt;
pub const instructionBarrier = arch.instructionBarrier;
pub const halt = arch.halt;
pub const spinWaitEq16 = arch.spinWaitEq16;
pub const speculationBarrier = arch.speculationBarrier;
pub const setKernelStack = arch.setKernelStack;
pub const currentId = arch.currentId;
