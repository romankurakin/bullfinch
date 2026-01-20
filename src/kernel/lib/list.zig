//! Intrusive Doubly-Linked List.
//!
//! A generic doubly-linked list where nodes are embedded directly in the
//! containing structure (intrusive design). This avoids separate allocations
//! for list nodes and provides O(1) removal of arbitrary elements.
//!
//! Key properties:
//! - O(1) pushFront, pushBack, popFront, popBack
//! - O(1) remove (given pointer to element)
//! - No memory allocation (nodes embedded in elements)
//! - Cache-friendly (no pointer chasing for node metadata)
//!
//! Debug builds include checks to catch misuse (e.g. removing unlinked items).

const std = @import("std");
const builtin = @import("builtin");

const panic_msg = struct {
    const REMOVE_UNLINKED = "list: remove called on unlinked item";
};

/// Enable extra validation in debug builds.
const debug_kernel = builtin.mode == .Debug;

/// Intrusive list node to embed in your structure.
///
/// Example:
/// ```
/// const Page = struct {
///     node: ListNode = .{},
///     phys_addr: usize,
///     state: PageState,
/// };
/// ```
pub const ListNode = struct {
    prev: ?*ListNode = null,
    next: ?*ListNode = null,
};

/// Doubly-linked intrusive list.
///
/// Type parameters:
/// - `T`: The container type that embeds a ListNode
/// - `node_field`: Name of the ListNode field in T (as string)
///
/// Example:
/// ```
/// const Page = struct {
///     node: ListNode = .{},
///     data: u32,
/// };
///
/// var list = DoublyLinkedList(Page, "node"){};
/// var page = Page{ .data = 42 };
/// list.pushBack(&page);
/// ```
pub fn DoublyLinkedList(comptime T: type, comptime node_field: []const u8) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        len: usize = 0,

        const Self = @This();

        /// Get the ListNode from a container pointer.
        fn getNode(item: *T) *ListNode {
            return &@field(item, node_field);
        }

        /// Get the container pointer from a ListNode pointer.
        fn fromNode(node: *ListNode) *T {
            return @fieldParentPtr(node_field, node);
        }

        /// Add item to front of list. O(1).
        pub fn pushFront(self: *Self, item: *T) void {
            const node = getNode(item);

            node.prev = null;
            node.next = if (self.head) |h| getNode(h) else null;

            if (self.head) |h| {
                getNode(h).prev = node;
            } else {
                self.tail = item;
            }

            self.head = item;
            self.len += 1;
        }

        /// Add item to back of list. O(1).
        pub fn pushBack(self: *Self, item: *T) void {
            const node = getNode(item);

            node.next = null;
            node.prev = if (self.tail) |t| getNode(t) else null;

            if (self.tail) |t| {
                getNode(t).next = node;
            } else {
                self.head = item;
            }

            self.tail = item;
            self.len += 1;
        }

        /// Remove and return item from front of list. O(1).
        /// Returns null if list is empty.
        pub fn popFront(self: *Self) ?*T {
            const head = self.head orelse return null;
            self.remove(head);
            return head;
        }

        /// Remove and return item from back of list. O(1).
        /// Returns null if list is empty.
        pub fn popBack(self: *Self) ?*T {
            const tail = self.tail orelse return null;
            self.remove(tail);
            return tail;
        }

        /// Remove item from list. O(1).
        ///
        /// The item must be in this list. In debug builds, panics if the
        /// item appears unlinked. Release builds have undefined behavior
        /// if called on an item not in the list.
        pub fn remove(self: *Self, item: *T) void {
            const node = getNode(item);

            // Item should be linked (head/tail, or have prev/next)
            if (debug_kernel) {
                const is_head = self.head == item;
                const is_tail = self.tail == item;
                const has_links = node.prev != null or node.next != null;
                if (!is_head and !is_tail and !has_links) {
                    @panic(panic_msg.REMOVE_UNLINKED);
                }
            }

            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = if (node.next) |next| fromNode(next) else null;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = if (node.prev) |prev| fromNode(prev) else null;
            }

            node.prev = null;
            node.next = null;
            self.len -= 1;
        }

        /// Check if item is in a list (has valid links or is singleton).
        /// Note: Cannot determine *which* list the item is in.
        pub fn contains(self: *Self, item: *T) bool {
            // If it's the head or tail, it's definitely in this list
            if (self.head == item or self.tail == item) return true;

            // If list is empty and item is not head/tail, it's not here
            if (self.head == null) return false;

            // Walk the list to check (O(n) but useful for debugging)
            var current = self.head;
            while (current) |c| {
                if (c == item) return true;
                const node = getNode(c);
                current = if (node.next) |n| fromNode(n) else null;
            }
            return false;
        }

        /// Returns true if list is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.head == null;
        }

        /// Returns first item without removing it.
        pub fn first(self: *Self) ?*T {
            return self.head;
        }

        /// Returns last item without removing it.
        pub fn last(self: *Self) ?*T {
            return self.tail;
        }

        /// Iterator for forward traversal.
        pub fn iterator(self: *Self) Iterator {
            return .{ .current = self.head };
        }

        pub const Iterator = struct {
            current: ?*T,

            pub fn next(self: *Iterator) ?*T {
                const item = self.current orelse return null;
                const node = getNode(item);
                self.current = if (node.next) |n| fromNode(n) else null;
                return item;
            }
        };
    };
}

const TestItem = struct {
    node: ListNode = .{},
    value: u32,
};

const TestList = DoublyLinkedList(TestItem, "node");

test "DoublyLinkedList empty list" {
    var list = TestList{};

    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), list.len);
    try std.testing.expectEqual(@as(?*TestItem, null), list.first());
    try std.testing.expectEqual(@as(?*TestItem, null), list.last());
    try std.testing.expectEqual(@as(?*TestItem, null), list.popFront());
    try std.testing.expectEqual(@as(?*TestItem, null), list.popBack());
}

test "DoublyLinkedList pushFront single item" {
    var list = TestList{};
    var item = TestItem{ .value = 42 };

    list.pushFront(&item);

    try std.testing.expect(!list.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(&item, list.first().?);
    try std.testing.expectEqual(&item, list.last().?);
}

test "DoublyLinkedList pushBack single item" {
    var list = TestList{};
    var item = TestItem{ .value = 42 };

    list.pushBack(&item);

    try std.testing.expect(!list.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(&item, list.first().?);
    try std.testing.expectEqual(&item, list.last().?);
}

test "DoublyLinkedList pushFront ordering" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };
    var c = TestItem{ .value = 3 };

    list.pushFront(&a); // [a]
    list.pushFront(&b); // [b, a]
    list.pushFront(&c); // [c, b, a]

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(&c, list.first().?);
    try std.testing.expectEqual(&a, list.last().?);

    // Pop in order: c, b, a
    try std.testing.expectEqual(@as(u32, 3), list.popFront().?.value);
    try std.testing.expectEqual(@as(u32, 2), list.popFront().?.value);
    try std.testing.expectEqual(@as(u32, 1), list.popFront().?.value);
    try std.testing.expect(list.isEmpty());
}

test "DoublyLinkedList pushBack ordering" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };
    var c = TestItem{ .value = 3 };

    list.pushBack(&a); // [a]
    list.pushBack(&b); // [a, b]
    list.pushBack(&c); // [a, b, c]

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(&a, list.first().?);
    try std.testing.expectEqual(&c, list.last().?);

    // Pop from front: a, b, c
    try std.testing.expectEqual(@as(u32, 1), list.popFront().?.value);
    try std.testing.expectEqual(@as(u32, 2), list.popFront().?.value);
    try std.testing.expectEqual(@as(u32, 3), list.popFront().?.value);
    try std.testing.expect(list.isEmpty());
}

test "DoublyLinkedList popBack" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };
    var c = TestItem{ .value = 3 };

    list.pushBack(&a);
    list.pushBack(&b);
    list.pushBack(&c);

    // Pop from back: c, b, a
    try std.testing.expectEqual(@as(u32, 3), list.popBack().?.value);
    try std.testing.expectEqual(@as(u32, 2), list.popBack().?.value);
    try std.testing.expectEqual(@as(u32, 1), list.popBack().?.value);
    try std.testing.expect(list.isEmpty());
}

test "DoublyLinkedList remove from middle" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };
    var c = TestItem{ .value = 3 };

    list.pushBack(&a);
    list.pushBack(&b);
    list.pushBack(&c);

    // Remove middle element
    list.remove(&b);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(&a, list.first().?);
    try std.testing.expectEqual(&c, list.last().?);

    // Verify links: a -> c
    try std.testing.expectEqual(@as(u32, 1), list.popFront().?.value);
    try std.testing.expectEqual(@as(u32, 3), list.popFront().?.value);
}

test "DoublyLinkedList remove head" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };

    list.pushBack(&a);
    list.pushBack(&b);

    list.remove(&a);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(&b, list.first().?);
    try std.testing.expectEqual(&b, list.last().?);
}

test "DoublyLinkedList remove tail" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };

    list.pushBack(&a);
    list.pushBack(&b);

    list.remove(&b);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(&a, list.first().?);
    try std.testing.expectEqual(&a, list.last().?);
}

test "DoublyLinkedList remove only item" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };

    list.pushBack(&a);
    list.remove(&a);

    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "DoublyLinkedList iterator" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };
    var c = TestItem{ .value = 3 };

    list.pushBack(&a);
    list.pushBack(&b);
    list.pushBack(&c);

    var iter = list.iterator();
    var sum: u32 = 0;
    while (iter.next()) |item| {
        sum += item.value;
    }

    try std.testing.expectEqual(@as(u32, 6), sum);
}

test "DoublyLinkedList contains" {
    var list = TestList{};
    var a = TestItem{ .value = 1 };
    var b = TestItem{ .value = 2 };
    var c = TestItem{ .value = 3 };

    list.pushBack(&a);
    list.pushBack(&b);

    try std.testing.expect(list.contains(&a));
    try std.testing.expect(list.contains(&b));
    try std.testing.expect(!list.contains(&c));
}

test "ListNode size" {
    // Two optional pointers = 16 bytes on 64-bit
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ListNode));
}
