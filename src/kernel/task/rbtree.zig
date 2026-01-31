//! Intrusive Red-Black Tree.
//!
//! Self-balancing binary search tree with O(log n) insert, delete, and lookup.
//! Maintains a cached pointer to the minimum node for O(1) min access.
//!
//! ```
//! // Embed node in your struct:
//! rb_node: rbtree.Node = .{},
//!
//! // Create tree with comparison function:
//! const RunQueue = RedBlackTree(Thread, "rb_node", compareVruntime);
//! var runqueue = RunQueue{};
//!
//! // Operations:
//! runqueue.insert(&thread.rb_node);
//! const next = RunQueue.entry(runqueue.min().?);
//! runqueue.remove(&thread.rb_node);

const std = @import("std");
const builtin = @import("builtin");

const debug_kernel = builtin.mode == .Debug;

const panic_msg = struct {
    const DOUBLE_INSERT = "rbtree: node already in tree";
    const NOT_IN_TREE = "rbtree: node not in tree";
    const INVARIANT_VIOLATED = "rbtree: invariant violated";
};

/// Node color.
pub const Color = enum(u1) {
    red = 0,
    black = 1,
};

/// Intrusive tree node.
pub const Node = struct {
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,
    color: Color = .red,

    /// True unless explicitly removed (parent points to self).
    pub fn isLinked(self: *const Node) bool {
        if (self.parent) |p| {
            return @intFromPtr(p) != @intFromPtr(self);
        }
        return true;
    }
};

/// Comparison result for tree ordering.
pub const Order = std.math.Order;

/// Red-Black Tree with O(log n) operations and O(1) cached min access.
pub fn RedBlackTree(
    comptime T: type,
    comptime field_name: []const u8,
    comptime compareFn: fn (*const T, *const T) Order,
) type {
    return struct {
        root: ?*Node = null,
        min_cached: ?*Node = null,
        count: usize = 0,

        const Self = @This();

        /// Get containing struct from node pointer.
        pub fn entry(node: *Node) *T {
            return @alignCast(@fieldParentPtr(field_name, node));
        }

        /// Get containing struct from node pointer (const).
        pub fn entryConst(node: *const Node) *const T {
            return @alignCast(@fieldParentPtr(field_name, @constCast(node)));
        }

        /// Insert node into tree. Node must not already be in a tree.
        pub fn insert(self: *Self, node: *Node) void {
            if (debug_kernel) {
                // Allow if parent is null (fresh) or self (removed)
                if (node.parent) |p| {
                    if (@intFromPtr(p) != @intFromPtr(node)) {
                        @panic(panic_msg.DOUBLE_INSERT);
                    }
                }
            }

            node.left = null;
            node.right = null;
            node.color = .red;

            const node_entry = entry(node);

            // BST insert - find parent
            var parent: ?*Node = null;
            var current = self.root;

            while (current) |cur| {
                parent = cur;
                const cur_entry = entry(cur);
                if (compareFn(node_entry, cur_entry) == .lt) {
                    current = cur.left;
                } else {
                    current = cur.right;
                }
            }

            node.parent = parent;

            if (parent) |p| {
                const parent_entry = entry(p);
                if (compareFn(node_entry, parent_entry) == .lt) {
                    p.left = node;
                } else {
                    p.right = node;
                }
            } else {
                self.root = node;
            }

            self.count += 1;

            // Update min cache
            if (self.min_cached) |min_node| {
                if (compareFn(node_entry, entry(min_node)) == .lt) {
                    self.min_cached = node;
                }
            } else {
                self.min_cached = node;
            }

            // Rebalance
            self.insertFixup(node);

            if (debug_kernel) self.verify();
        }

        /// Remove node from tree.
        pub fn remove(self: *Self, node: *Node) void {
            if (debug_kernel) {
                if (!node.isLinked()) {
                    @panic(panic_msg.NOT_IN_TREE);
                }
            }

            // Update min cache before removal
            if (self.min_cached == node) {
                self.min_cached = self.nextNode(node);
            }

            var y: *Node = undefined;
            var x: ?*Node = undefined;
            var x_parent: ?*Node = undefined;

            // Find node to splice out
            if (node.left == null or node.right == null) {
                y = node;
            } else {
                // Find successor
                y = node.right.?;
                while (y.left) |left| {
                    y = left;
                }
            }

            // x is y's only child (or null)
            x = if (y.left != null) y.left else y.right;
            x_parent = y.parent;

            // Splice out y
            if (x) |x_node| {
                x_node.parent = y.parent;
            }

            if (y.parent) |yp| {
                if (y == yp.left) {
                    yp.left = x;
                } else {
                    yp.right = x;
                }
            } else {
                self.root = x;
            }

            const need_fixup = y.color == .black;

            // If y != node, replace node with y
            if (y != node) {
                y.parent = node.parent;
                y.left = node.left;
                y.right = node.right;
                y.color = node.color;

                if (node.parent) |np| {
                    if (node == np.left) {
                        np.left = y;
                    } else {
                        np.right = y;
                    }
                } else {
                    self.root = y;
                }

                if (y.left) |yl| {
                    yl.parent = y;
                }
                if (y.right) |yr| {
                    yr.parent = y;
                }

                if (x_parent == node) {
                    x_parent = y;
                }
            }

            // Mark unlinked
            node.parent = node;
            node.left = null;
            node.right = null;
            node.color = .red;
            self.count -= 1;

            // Fixup if we removed a black node
            if (need_fixup) {
                self.deleteFixup(x, x_parent);
            }

            if (debug_kernel) self.verify();
        }

        /// Get minimum node. O(1) cached.
        pub fn min(self: *const Self) ?*Node {
            return self.min_cached;
        }

        /// Get minimum and remove it. O(log n).
        pub fn extractMin(self: *Self) ?*Node {
            const min_node = self.min() orelse return null;
            self.remove(min_node);
            return min_node;
        }

        /// Find node by key (first match).
        pub fn find(self: *const Self, key: *const T) ?*Node {
            var current = self.root;
            while (current) |cur| {
                const cur_entry = entryConst(cur);
                switch (compareFn(key, cur_entry)) {
                    .lt => current = cur.left,
                    .gt => current = cur.right,
                    .eq => return cur,
                }
            }
            return null;
        }

        /// Get next node in order (successor).
        pub fn nextNode(self: *const Self, node: *Node) ?*Node {
            _ = self;
            // If right subtree exists, min of right subtree
            if (node.right) |right| {
                var n = right;
                while (n.left) |left| {
                    n = left;
                }
                return n;
            }

            // Walk up until we're a left child
            var n = node;
            while (n.parent) |parent| {
                if (n == parent.left) {
                    return parent;
                }
                n = parent;
            }
            return null;
        }

        /// Check if tree is empty.
        pub fn isEmpty(self: *const Self) bool {
            return self.root == null;
        }

        /// Get number of nodes.
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        fn insertFixup(self: *Self, n: *Node) void {
            var node = n;

            while (node.parent) |parent| {
                if (parent.color == .black) break;

                const grandparent = parent.parent orelse break;

                if (parent == grandparent.left) {
                    const uncle = grandparent.right;
                    if (uncle != null and uncle.?.color == .red) {
                        // Case 1: uncle is red
                        parent.color = .black;
                        uncle.?.color = .black;
                        grandparent.color = .red;
                        node = grandparent;
                    } else {
                        if (node == parent.right) {
                            // Case 2: uncle is black, node is right child
                            node = parent;
                            self.leftRotate(node);
                        }
                        // Case 3: uncle is black, node is left child
                        node.parent.?.color = .black;
                        node.parent.?.parent.?.color = .red;
                        self.rightRotate(node.parent.?.parent.?);
                    }
                } else {
                    // Mirror cases
                    const uncle = grandparent.left;
                    if (uncle != null and uncle.?.color == .red) {
                        parent.color = .black;
                        uncle.?.color = .black;
                        grandparent.color = .red;
                        node = grandparent;
                    } else {
                        if (node == parent.left) {
                            node = parent;
                            self.rightRotate(node);
                        }
                        node.parent.?.color = .black;
                        node.parent.?.parent.?.color = .red;
                        self.leftRotate(node.parent.?.parent.?);
                    }
                }
            }

            if (self.root) |root| {
                root.color = .black;
            }
        }

        fn deleteFixup(self: *Self, x_opt: ?*Node, x_parent_opt: ?*Node) void {
            var x = x_opt;
            var x_parent = x_parent_opt;

            while (x != self.root and (x == null or x.?.color == .black)) {
                const parent = x_parent orelse break;

                if (x == parent.left) {
                    var w = parent.right orelse break;

                    if (w.color == .red) {
                        w.color = .black;
                        parent.color = .red;
                        self.leftRotate(parent);
                        w = parent.right orelse break;
                    }

                    const w_left_black = w.left == null or w.left.?.color == .black;
                    const w_right_black = w.right == null or w.right.?.color == .black;

                    if (w_left_black and w_right_black) {
                        w.color = .red;
                        x = parent;
                        x_parent = parent.parent;
                    } else {
                        if (w_right_black) {
                            if (w.left) |wl| wl.color = .black;
                            w.color = .red;
                            self.rightRotate(w);
                            w = parent.right orelse break;
                        }
                        w.color = parent.color;
                        parent.color = .black;
                        if (w.right) |wr| wr.color = .black;
                        self.leftRotate(parent);
                        x = self.root;
                        x_parent = null;
                    }
                } else {
                    // Mirror case
                    var w = parent.left orelse break;

                    if (w.color == .red) {
                        w.color = .black;
                        parent.color = .red;
                        self.rightRotate(parent);
                        w = parent.left orelse break;
                    }

                    const w_left_black = w.left == null or w.left.?.color == .black;
                    const w_right_black = w.right == null or w.right.?.color == .black;

                    if (w_left_black and w_right_black) {
                        w.color = .red;
                        x = parent;
                        x_parent = parent.parent;
                    } else {
                        if (w_left_black) {
                            if (w.right) |wr| wr.color = .black;
                            w.color = .red;
                            self.leftRotate(w);
                            w = parent.left orelse break;
                        }
                        w.color = parent.color;
                        parent.color = .black;
                        if (w.left) |wl| wl.color = .black;
                        self.rightRotate(parent);
                        x = self.root;
                        x_parent = null;
                    }
                }
            }

            if (x) |x_node| {
                x_node.color = .black;
            }
        }

        fn leftRotate(self: *Self, node: *Node) void {
            const y = node.right orelse return;
            node.right = y.left;

            if (y.left) |yl| {
                yl.parent = node;
            }

            y.parent = node.parent;

            if (node.parent) |np| {
                if (node == np.left) {
                    np.left = y;
                } else {
                    np.right = y;
                }
            } else {
                self.root = y;
            }

            y.left = node;
            node.parent = y;
        }

        fn rightRotate(self: *Self, node: *Node) void {
            const y = node.left orelse return;
            node.left = y.right;

            if (y.right) |yr| {
                yr.parent = node;
            }

            y.parent = node.parent;

            if (node.parent) |np| {
                if (node == np.right) {
                    np.right = y;
                } else {
                    np.left = y;
                }
            } else {
                self.root = y;
            }

            y.right = node;
            node.parent = y;
        }

        fn verify(self: *const Self) void {
            const root = self.root orelse return;

            // Root must be black
            if (root.color != .black) @panic(panic_msg.INVARIANT_VIOLATED);

            // Verify properties recursively
            _ = self.verifyNode(root) catch @panic(panic_msg.INVARIANT_VIOLATED);

            // Verify min cache
            if (self.count > 0) {
                var min_node = root;
                while (min_node.left) |left| {
                    min_node = left;
                }
                if (self.min_cached != min_node) @panic(panic_msg.INVARIANT_VIOLATED);
            }
        }

        fn verifyNode(self: *const Self, node: *Node) error{Invalid}!usize {
            // Red node cannot have red child
            if (node.color == .red) {
                if (node.left != null and node.left.?.color == .red) return error.Invalid;
                if (node.right != null and node.right.?.color == .red) return error.Invalid;
            }

            // Check parent pointers
            if (node.left) |left| {
                if (left.parent != node) return error.Invalid;
            }
            if (node.right) |right| {
                if (right.parent != node) return error.Invalid;
            }

            // Check BST property
            if (node.left) |left| {
                if (compareFn(entry(left), entry(node)) == .gt) return error.Invalid;
            }
            if (node.right) |right| {
                if (compareFn(entry(right), entry(node)) == .lt) return error.Invalid;
            }

            // Verify black height
            const left_black = if (node.left) |left|
                try self.verifyNode(left)
            else
                1;
            const right_black = if (node.right) |right|
                try self.verifyNode(right)
            else
                1;

            if (left_black != right_black) return error.Invalid;

            return left_black + @as(usize, if (node.color == .black) 1 else 0);
        }
    };
}

const TestItem = struct {
    key: u64,
    rb_node: Node = .{},

    fn compare(a: *const TestItem, b: *const TestItem) Order {
        return std.math.order(a.key, b.key);
    }
};

const TestTree = RedBlackTree(TestItem, "rb_node", TestItem.compare);

test "initializes empty tree" {
    const tree = TestTree{};
    try std.testing.expect(tree.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), tree.len());
    try std.testing.expectEqual(@as(?*Node, null), tree.min());
}

test "inserts single node" {
    var tree = TestTree{};
    var item = TestItem{ .key = 42 };

    tree.insert(&item.rb_node);

    try std.testing.expect(!tree.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), tree.len());
    try std.testing.expectEqual(&item.rb_node, tree.min().?);
    try std.testing.expectEqual(@as(u64, 42), TestTree.entry(tree.min().?).key);
}

test "maintains min on ascending insert" {
    var tree = TestTree{};
    var items: [5]TestItem = undefined;

    for (&items, 0..) |*item, i| {
        item.* = .{ .key = @intCast(i + 1) };
        tree.insert(&item.rb_node);
        try std.testing.expectEqual(@as(u64, 1), TestTree.entry(tree.min().?).key);
    }
}

test "maintains min on descending insert" {
    var tree = TestTree{};
    var items: [5]TestItem = undefined;

    for (&items, 0..) |*item, i| {
        item.* = .{ .key = @intCast(5 - i) };
        tree.insert(&item.rb_node);
        try std.testing.expectEqual(@as(u64, 5 - i), TestTree.entry(tree.min().?).key);
    }
}

test "extracts min in sorted order" {
    var tree = TestTree{};
    var items: [10]TestItem = undefined;

    // Insert in scrambled order
    const order = [_]u64{ 5, 2, 8, 1, 9, 3, 7, 4, 6, 10 };
    for (order, 0..) |key, i| {
        items[i] = .{ .key = key };
        tree.insert(&items[i].rb_node);
    }

    // Extract should yield sorted order
    var expected: u64 = 1;
    while (tree.extractMin()) |node| {
        const item = TestTree.entry(node);
        try std.testing.expectEqual(expected, item.key);
        expected += 1;
    }
    try std.testing.expectEqual(@as(u64, 11), expected);
    try std.testing.expect(tree.isEmpty());
}

test "removes arbitrary node" {
    var tree = TestTree{};
    var items: [5]TestItem = undefined;

    for (&items, 0..) |*item, i| {
        item.* = .{ .key = @intCast(i + 1) };
        tree.insert(&item.rb_node);
    }

    // Remove middle node
    tree.remove(&items[2].rb_node);
    try std.testing.expectEqual(@as(usize, 4), tree.len());

    // Verify remaining nodes
    var count: usize = 0;
    var current = tree.min();
    while (current) |node| {
        const item = TestTree.entry(node);
        try std.testing.expect(item.key != 3);
        count += 1;
        current = tree.nextNode(node);
    }
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "finds node by key" {
    var tree = TestTree{};
    var items: [5]TestItem = undefined;

    for (&items, 0..) |*item, i| {
        item.* = .{ .key = @intCast((i + 1) * 10) };
        tree.insert(&item.rb_node);
    }

    var search_key = TestItem{ .key = 30 };
    const found = tree.find(&search_key);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 30), TestTree.entry(found.?).key);

    search_key.key = 999;
    try std.testing.expectEqual(@as(?*Node, null), tree.find(&search_key));
}

test "handles many insertions and deletions" {
    var tree = TestTree{};
    var items: [100]TestItem = undefined;

    // Insert all
    for (&items, 0..) |*item, i| {
        item.* = .{ .key = @intCast(i) };
        tree.insert(&item.rb_node);
    }
    try std.testing.expectEqual(@as(usize, 100), tree.len());

    // Remove half (even indices)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        tree.remove(&items[i * 2].rb_node);
    }
    try std.testing.expectEqual(@as(usize, 50), tree.len());

    // Verify remaining are odd indices
    var count: usize = 0;
    var current = tree.min();
    while (current) |node| {
        const item = TestTree.entry(node);
        try std.testing.expect(item.key % 2 == 1);
        count += 1;
        current = tree.nextNode(node);
    }
    try std.testing.expectEqual(@as(usize, 50), count);
}

test "handles duplicate keys" {
    var tree = TestTree{};
    var items: [5]TestItem = undefined;

    for (&items) |*item| {
        item.* = .{ .key = 42 };
        tree.insert(&item.rb_node);
    }

    try std.testing.expectEqual(@as(usize, 5), tree.len());

    // All should be extractable
    var count: usize = 0;
    while (tree.extractMin()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
}
