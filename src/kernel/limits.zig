//! Kernel capacity limits.
//!
//! Bounds for static kernel data structures. These limits exist because
//! the kernel uses fixed-size arrays during early boot before dynamic
//! allocation is available.

/// Maximum disjoint physical memory regions. Most systems have 1-2 regions
/// (main RAM, possibly high memory above 4GB). Systems with memory holes
/// or NUMA may have more. Cost: ~200 bytes per slot.
pub const MAX_MEMORY_ARENAS = 4;

/// Maximum reserved address ranges (kernel image, device tree, firmware).
pub const MAX_RESERVED_REGIONS = 8;

/// Maximum number of CPUs supported by static per-CPU structures.
pub const MAX_CPUS = 32;
