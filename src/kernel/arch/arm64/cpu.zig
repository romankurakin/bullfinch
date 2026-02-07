//! ARM64 CPU Primitives.
//!
//! Low-level interrupt control, synchronization, and speculation barriers.
//! See ARM Architecture Reference Manual for instruction details.

/// Disable IRQ and FIQ. Returns true if IRQs were previously enabled.
pub inline fn disableInterrupts() bool {
    var daif: u64 = undefined;
    asm volatile ("mrs %[daif], daif"
        : [daif] "=r" (daif),
    );
    asm volatile ("msr daifset, #3");
    return (daif & 0x80) == 0;
}

/// Enable IRQ and FIQ.
pub inline fn enableInterrupts() void {
    asm volatile ("msr daifclr, #3");
}

/// Wait for interrupt (low-power sleep until IRQ/FIQ/abort).
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}

/// Instruction synchronization barrier.
pub inline fn instructionBarrier() void {
    asm volatile ("isb");
}

/// Full-system data synchronization barrier.
pub inline fn dataSyncBarrierSy() void {
    asm volatile ("dsb sy");
}

/// Inner-shareable data synchronization barrier.
pub inline fn dataSyncBarrierIsh() void {
    asm volatile ("dsb ish");
}

/// Inner-shareable store-only data synchronization barrier.
pub inline fn dataSyncBarrierIshst() void {
    asm volatile ("dsb ishst");
}

/// Set kernel exception stack pointer (SP_EL1).
pub inline fn setKernelStack(sp: usize) void {
    asm volatile ("msr sp_el1, %[sp]"
        :
        : [sp] "r" (sp),
    );
}

/// Return current CPU ID (MPIDR_EL1 affinity level 0).
pub inline fn currentId() usize {
    const mpidr = asm volatile ("mrs %[ret], mpidr_el1"
        : [ret] "=r" (-> u64),
    );
    return @as(usize, @truncate(mpidr & 0xff));
}

/// Halt CPU forever (interrupts remain enabled).
pub inline fn halt() noreturn {
    while (true) asm volatile ("wfi");
}

/// Spin until low 16 bits of value at `ptr` equals `expected`.
/// Uses exclusive monitor + WFE for power-efficient waiting.
pub fn spinWaitEq16(ptr: *const u32, expected: u16) void {
    asm volatile ("sevl");
    while (true) {
        // LDAXR sets exclusive monitor; any store clears it (waking WFE).
        const val: u16 = @truncate(asm volatile ("ldaxr %[val], [%[ptr]]"
            : [val] "=&r" (-> u32),
            : [ptr] "r" (ptr),
            : .{ .memory = true }));
        if (val == expected) break;
        asm volatile ("wfe");
    }
}

/// Speculation barrier (CSDB). Use after bounds checks on untrusted indices.
pub inline fn speculationBarrier() void {
    asm volatile ("csdb");
}
