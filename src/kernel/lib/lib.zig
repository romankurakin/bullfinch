//! Kernel Standard Library.
//!
//! Generic data structures and utilities for kernel use.

pub const list = @import("list.zig");
pub const ListNode = list.ListNode;
pub const DoublyLinkedList = list.DoublyLinkedList;

comptime {
    _ = list;
}
