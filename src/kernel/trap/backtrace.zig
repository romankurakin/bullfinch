//! Backtrace Support.
//!
//! Lock-free frame pointer walker for panic context. Walks the call stack
//! by following the frame pointer chain.
//!
//! Frame layout is architecture-specific - see hal/trap_frame.zig for details.
//! Requires code compiled with frame pointers enabled (-fno-omit-frame-pointer).

const console = @import("../console/console.zig");
const fmt = @import("fmt.zig");
const hal = @import("../hal/hal.zig");

// Use printUnsafe in trap context: we can't safely acquire locks here
const print = console.printUnsafe;

/// Maximum stack depth to prevent infinite loops on corrupted stacks.
const MAX_DEPTH = 16;

/// Kernel address space starts at this address (higher half).
/// Used to validate frame pointer addresses.
const KERNEL_BASE: usize = 0xFFFF_0000_0000_0000;

/// Print a backtrace starting from the given frame pointer and PC.
/// Frame #0 shows the current PC, subsequent frames show return addresses.
pub fn printBacktrace(fp: usize, pc: usize) void {
    print("\n");

    // Frame #0: current instruction
    printFrame(0, pc);

    // Walk frame pointer chain
    var current_fp = fp;
    var depth: usize = 1;

    while (depth < MAX_DEPTH) {
        // Stop at null frame pointer (stack bottom)
        if (current_fp == 0) break;

        // Validate frame pointer is in kernel space and aligned
        if (!isValidFramePointer(current_fp)) break;

        // Read previous frame pointer and return address (arch-specific layout)
        const prev_fp, const ret_addr = readFrame(current_fp);

        // Stop if return address looks invalid
        if (ret_addr == 0) break;

        printFrame(depth, ret_addr);

        current_fp = prev_fp;
        depth += 1;
    }
}

/// Read frame pointer and return address from stack frame.
/// Delegates to arch-specific implementation via HAL.
const readFrame = hal.trap_frame.readStackFrame;

/// Check if a frame pointer value could be valid.
fn isValidFramePointer(fp: usize) bool {
    // Must be in kernel address space
    if (fp < KERNEL_BASE) return false;

    // Must be 16-byte aligned (ARM64 AAPCS64 / RISC-V ABI requirement)
    if (fp & 0xF != 0) return false;

    return true;
}

/// Print a single frame entry: "  #N  0x<address>".
fn printFrame(depth: usize, addr: usize) void {
    print("  #");
    const decimal = fmt.formatDecimal(depth);
    print(decimal.buf[0..decimal.len]);
    print("  0x");
    print(&fmt.formatHex(addr));
    print("\n");
}
