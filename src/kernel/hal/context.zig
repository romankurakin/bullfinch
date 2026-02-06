//! Context Switch HAL.
//!
//! Provides architecture-independent access to thread context switching.
//! The Context struct contains callee-saved registers for voluntary context
//! switches between threads.

const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => @import("../arch/arm64/context.zig"),
    .riscv64 => @import("../arch/riscv64/context.zig"),
    else => @compileError("Unsupported architecture"),
};

const panic_msg = struct {
    const EXIT_NOT_SET = "context: exit function not set";
};

pub const Context = arch.Context;
pub const switchContext = arch.switchContext;
pub const threadTrampoline = arch.threadTrampoline;

pub const EntryFn = *const fn (?*anyopaque) void;
pub const ExitFn = *const fn () noreturn;

var exit_fn: ?ExitFn = null;
// TODO(smp): Publish exit_fn with release/acquire semantics for secondary CPUs.

/// Set the thread exit function. Called once during scheduler init.
pub fn setExitFn(f: ExitFn) void {
    exit_fn = f;
}

/// Called from arch trampoline after thread entry returns.
export fn threadStart(entry: usize, arg: usize) callconv(.c) noreturn {
    const func: EntryFn = @ptrFromInt(entry);
    const ptr: ?*anyopaque = if (arg == 0) null else @ptrFromInt(arg);

    func(ptr);

    const thread_exit = exit_fn orelse @panic(panic_msg.EXIT_NOT_SET);
    thread_exit();
}

comptime {
    if (!@hasDecl(Context, "SIZE")) @compileError("Context must have SIZE constant");
    if (Context.SIZE != @sizeOf(Context)) @compileError("Context.SIZE must match @sizeOf(Context)");
    if (@sizeOf(Context) & 0xF != 0) @compileError("Context must be 16-byte aligned");
    if (!@hasDecl(Context, "init")) @compileError("Context must have init method");
    if (!@hasDecl(arch, "switchContext")) @compileError("arch must have switchContext function");
}
