//! Runtime services owned by the kernel binary.

pub mod clock;
#[cfg(feature = "smoke-test")]
pub mod smoke;
pub mod trap;
