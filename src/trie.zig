//! `PlumTrie`: the tree at the heart of the Plum data structure.
//!
//! A key is split on a delimiter, `:` by default, into segments, and each segment is one step down the tree.
//! Nodes are `PlumAtom`s. Their segment strings live in a shared `InternPool`.
//!
//! After setting `user:1001:name`, `user:1001:email` and `user:1002:name`:
//!
//! ```
//! root ""
//! └── user                      (no value)
//!     ├── 1001                  (no value)
//!     │   ├── name   = "Alice"      path ─┐
//!     │   └── email  = "..."              ├─> one interned "name", count 2
//!     └── 1002                  (no value)│
//!         └── name   = "Bob"        path ─┘
//!
//! InternPool: ""=1  user=1  1001=1  1002=1  name=2  email=1
//! ```
//!
//! Each operation takes O(m) time on average for a key of m bytes. Deleting also
//! costs time proportional to the size of the removed branch.

const std = @import("std");
const atom = @import("atom.zig");
const intern = @import("intern.zig");
const tokenize = @import("tokenize.zig");

/// Hands out strictly increasing times, so that no two changes tie. A trie and
/// its snapshots share one, across threads.
pub const Clock = struct {
    last: std.atomic.Value(i64) = .init(0),

    pub fn next(self: *Clock, io: std.Io) i96 {
        const now: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
        var previous = self.last.load(.monotonic);
        while (true) {
            const time = @max(now, previous + 1);
            previous = self.last.cmpxchgWeak(previous, time, .monotonic, .monotonic) orelse return time;
        }
    }
};

/// Deleted paths and when they were deleted. A path is encoded as each segment
/// prefixed with its length.
pub const Deletions = std.StringHashMapUnmanaged(i96);

/// Appends one segment to an encoded path.
pub fn appendSegment(gpa: std.mem.Allocator, path: *std.ArrayList(u8), segment: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(segment.len), .little);
    try path.appendSlice(gpa, &length);
    try path.appendSlice(gpa, segment);
}

/// A trie of `PlumAtom`s indexed by the segments of delimited keys.
///
/// With the default delimiter, empty segments are ignored, so `a::b` and
/// `:a:b:` mean the same as `a:b`. A key with no segments, such as `:`, refers
/// to the root.
pub const PlumTrie = struct {
    /// The pool holding every segment string. The trie does not own it.
    interner: *intern.InternPool,
    /// The string that splits keys into segments. The trie does not own it.
    delimiter: []const u8,
    /// The root node. Its segment is the empty string.
    root: atom.PlumAtom,
    /// Process context. Its `gpa` allocates nodes and values.
    __proc: std.process.Init,
    /// The source of modification times, shared with snapshots.
    clock: *Clock,
    /// Whether this trie created `clock`, and so frees it.
    owns_clock: bool = true,
    /// Whether deletes are recorded, as they must be while snapshots that will
    /// be merged back exist.
    record_deletes: bool = false,
    /// The recorded deletes.
    deletions: Deletions = .empty,

    /// Creates a trie containing only the root node.
    ///
    /// `interner` and `delimiter` must outlive the trie. `delimiter` must not be
    /// empty.
    pub fn init(proc: std.process.Init, interner: *intern.InternPool, delimiter: []const u8) !PlumTrie {
        const clock = try proc.gpa.create(Clock);
        errdefer proc.gpa.destroy(clock);
        clock.* = .{};
        return PlumTrie{
            .clock = clock,
            .delimiter = delimiter,
            .__proc = proc,
            .interner = interner,
            .root = try atom.PlumAtom.init(proc, "", interner), // Initialize the root node with an empty key.
        };
    }

    /// Frees every node and value, and releases their segments from the pool.
    pub fn deinit(self: *PlumTrie) void {
        // Recursively deinitialize the root atom, which will deinitialize all its children.
        self.root.deinit(self.interner);
        self.forgetDeletions(std.math.maxInt(i96));
        self.deletions.deinit(self.__proc.gpa);
        if (self.owns_clock) self.__proc.gpa.destroy(self.clock);
    }

    /// Records a delete of the encoded `path` at `time`, keeping the latest.
    pub fn recordDelete(self: *PlumTrie, path: []const u8, time: i96) error{OutOfMemory}!void {
        const entry = try self.deletions.getOrPut(self.__proc.gpa, path);
        if (entry.found_existing) {
            entry.value_ptr.* = @max(entry.value_ptr.*, time);
            return;
        }
        errdefer self.deletions.removeByPtr(entry.key_ptr);
        entry.key_ptr.* = try self.__proc.gpa.dupe(u8, path);
        entry.value_ptr.* = time;
    }

    /// Drops records of deletes made before `time`. Safe once no snapshot taken
    /// before then remains to be merged.
    pub fn forgetDeletions(self: *PlumTrie, time: i96) void {
        // Removing leaves other entries in place, so iteration can continue. This
        // keeps one pass over many records.
        var entries = self.deletions.iterator();
        while (entries.next()) |entry| {
            if (entry.value_ptr.* >= time) continue;
            const path = entry.key_ptr.*;
            self.deletions.removeByPtr(entry.key_ptr);
            self.__proc.gpa.free(path);
        }
    }

    /// Returns the Merkle hash of the whole trie. See `PlumAtom.hash`.
    ///
    /// Equal hashes of two nodes mean their subtrees can be treated as the same
    /// without visiting them. Only `set` and `delete` keep hashes up to date:
    /// changing nodes directly leaves stale hashes behind.
    pub fn hash(self: *PlumTrie) atom.Digest {
        return self.root.hash();
    }

    /// Stores a copy of `value` at `full_key`, creating any missing nodes.
    ///
    /// An existing value is replaced. If allocation fails, nodes already created
    /// remain in the trie without a value.
    pub fn set(self: *PlumTrie, full_key: []const u8, value: []const u8) !void {
        // Tokenize the full key into segments. `null` indicates using the default delimiter.
        var tokens = tokenize.Tokenize(full_key, self.delimiter);
        // Start traversal from the root node.
        var current: *atom.PlumAtom = &self.root;

        // Iterate through each segment of the key.
        while (tokens.next()) |segment| {
            // Everything on the path is about to have a different subtree.
            current.invalidate(segment);
            // Try to find a child node corresponding to the current segment.
            const maybe_child = current.findChild(segment);

            if (maybe_child) |child| {
                // If a child exists, move to that child node.
                current = child;
            } else {
                // If no child exists, create a new `PlumAtom` for this segment and add it.
                current = try current.addChild(segment, self.interner);
            }
        }

        // Once at the final node, set its `PurePlumAtom`'s value.
        current.invalidate(null);
        try current.pure.setValue(value);
        current.pure.modified_at = self.clock.next(self.__proc.io);
    }

    /// Returns the value at `full_key`, or `null` if the node exists without one.
    ///
    /// Returns `error.KeyNotFound` if the path does not exist. Reaching a node
    /// updates its access metadata, even if it has no value.
    ///
    /// The returned slice belongs to the trie and is invalidated when the key is
    /// overwritten or deleted.
    pub fn get(self: *PlumTrie, full_key: []const u8) error{KeyNotFound}!?[]u8 {
        // Tokenize the full key into segments.
        var tokens = tokenize.Tokenize(full_key, self.delimiter);
        // Start traversal from the root node.
        var current: *atom.PlumAtom = &self.root;

        // Iterate through each segment of the key.
        while (tokens.next()) |segment| {
            // Try to find a child node corresponding to the current segment.
            // If not found, the key path does not exist, so return `error.KeyNotFound`.
            const child = current.findChild(segment) orelse return error.KeyNotFound;
            // Move to the found child node.
            current.accessed = true;
            current = child;
        }

        // Once at the final node, update its access count and return its value.
        current.accessed = true;
        current.pure.updateAccessCount();
        return current.pure.value;
    }

    /// Removes the node at `full_key` together with all of its descendants.
    ///
    /// Ancestors left without a value or children are kept. The root cannot be
    /// removed. Returns `error.KeyNotFound` if the path does not exist or the key
    /// has no segments.
    pub fn delete(self: *PlumTrie, full_key: []const u8) error{ KeyNotFound, OutOfMemory }!void {
        var tokens = tokenize.Tokenize(full_key, self.delimiter);
        var parent: *atom.PlumAtom = &self.root;
        var segment = tokens.next() orelse return error.KeyNotFound;

        // Walk down to the parent of the node being deleted.
        while (tokens.next()) |next_segment| {
            parent = parent.findChild(segment) orelse return error.KeyNotFound;
            segment = next_segment;
        }

        if (parent.findChild(segment) == null) return error.KeyNotFound;
        // Record first, so that running out of memory leaves the key in place.
        if (self.record_deletes) {
            var encoded: std.ArrayList(u8) = .empty;
            defer encoded.deinit(self.__proc.gpa);
            var path = tokenize.Tokenize(full_key, self.delimiter);
            while (path.next()) |part| try appendSegment(self.__proc.gpa, &encoded, part);
            try self.recordDelete(encoded.items, self.clock.next(self.__proc.io));
        }

        // The key exists, so clear the hashes of its ancestors.
        var path = tokenize.Tokenize(full_key, self.delimiter);
        var ancestor: *atom.PlumAtom = &self.root;
        while (path.next()) |part| {
            ancestor.invalidate(part);
            ancestor = ancestor.findChild(part) orelse break;
        }

        // Unlink the node first, then free it along with its descendants.
        const removed = parent.removeChild(segment).?;
        removed.deinit(self.interner);
        self.__proc.gpa.destroy(removed);
    }
};

test "set, get and delete nested keys" {
    const proc: std.process.Init = .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
    var pool = intern.InternPool.init(proc.gpa);
    defer pool.deinit();
    var trie = try PlumTrie.init(proc, &pool, ":");
    defer trie.deinit();

    try trie.set("user:1:name", "Alice");
    try trie.set("user:2:name", "Bob");
    try std.testing.expectEqualStrings("Alice", (try trie.get("user:1:name")).?);

    try trie.delete("user:1");
    try std.testing.expectError(error.KeyNotFound, trie.get("user:1:name"));
    try std.testing.expectEqualStrings("Bob", (try trie.get("user:2:name")).?);
}

fn testProc() std.process.Init {
    return .{
        .minimal = undefined,
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = undefined,
    };
}

const TestTrie = struct {
    pool: intern.InternPool,
    trie: PlumTrie,

    fn create() !*TestTrie {
        const self = try std.testing.allocator.create(TestTrie);
        self.pool = intern.InternPool.init(std.testing.allocator);
        self.trie = try PlumTrie.init(testProc(), &self.pool, ":");
        return self;
    }

    fn destroy(self: *TestTrie) void {
        self.trie.deinit();
        self.pool.deinit();
        std.testing.allocator.destroy(self);
    }
};

/// Drops every cached hash, and with `zero_times` makes the times equal.
fn reset(node: *atom.PlumAtom, zero_times: bool) void {
    node.cached_hash = null;
    if (node.groups) |groups| groups.hashes = @splat(null);
    if (zero_times) node.pure.modified_at = 0;
    var children = node.children.valueIterator();
    while (children.next()) |child| reset(child.*, zero_times);
}

fn node_hash(trie: *PlumTrie, first: []const u8, second: ?[]const u8) atom.Digest {
    var node = trie.root.findChild(first).?;
    if (second) |segment| node = node.findChild(segment).?;
    return node.hash();
}

fn expectDifferent(a: atom.Digest, b: atom.Digest) !void {
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "a write changes the hashes up to the root, and no others" {
    const t = try TestTrie.create();
    defer t.destroy();
    try t.trie.set("a:x", "1");
    try t.trie.set("b:y", "2");
    const root = t.trie.hash();
    const a = node_hash(&t.trie, "a", null);
    const ax = node_hash(&t.trie, "a", "x");
    const b = node_hash(&t.trie, "b", null);

    try t.trie.set("a:x", "changed");

    try expectDifferent(root, t.trie.hash());
    try expectDifferent(a, node_hash(&t.trie, "a", null));
    try expectDifferent(ax, node_hash(&t.trie, "a", "x"));
    try std.testing.expectEqual(b, node_hash(&t.trie, "b", null));
    // The untouched branch is not even recalculated.
    try std.testing.expect(t.trie.root.findChild("b").?.cached_hash != null);
}

test "a delete changes the hashes above it, and no others" {
    const t = try TestTrie.create();
    defer t.destroy();
    try t.trie.set("a:x", "1");
    try t.trie.set("a:z", "3");
    try t.trie.set("b:y", "2");
    const root = t.trie.hash();
    const a = node_hash(&t.trie, "a", null);
    const b = node_hash(&t.trie, "b", null);

    try t.trie.delete("a:x");

    try expectDifferent(root, t.trie.hash());
    try expectDifferent(a, node_hash(&t.trie, "a", null));
    try std.testing.expectEqual(b, node_hash(&t.trie, "b", null));
}

test "reads do not change the hash" {
    const t = try TestTrie.create();
    defer t.destroy();
    try t.trie.set("a:x", "1");
    const root = t.trie.hash();

    _ = try t.trie.get("a:x");
    reset(&t.trie.root, false);

    try std.testing.expectEqual(root, t.trie.hash());
}

test "writing a value back still changes the hash" {
    const t = try TestTrie.create();
    defer t.destroy();
    try t.trie.set("k", "A");
    const first = t.trie.hash();

    try t.trie.set("k", "B");
    try t.trie.set("k", "A");

    try expectDifferent(first, t.trie.hash());
}

test "the hash does not depend on insertion order" {
    const one = try TestTrie.create();
    defer one.destroy();
    const two = try TestTrie.create();
    defer two.destroy();
    var buf: [16]u8 = undefined;
    for (0..100) |i| try one.trie.set(try std.fmt.bufPrint(&buf, "n:{d}", .{i}), "v");
    for (0..100) |i| try two.trie.set(try std.fmt.bufPrint(&buf, "n:{d}", .{99 - i}), "v");
    reset(&one.trie.root, true);
    reset(&two.trie.root, true);

    try std.testing.expectEqual(one.trie.hash(), two.trie.hash());
}

test "moving bytes between fields or levels changes the hash" {
    const cases = [_][2][]const u8{
        .{ "ab", "c" }, .{ "a", "bc" }, .{ "a:b", "c" }, .{ "abc", "" },
    };
    var hashes: [cases.len]atom.Digest = undefined;
    for (cases, &hashes) |case, *out| {
        const t = try TestTrie.create();
        defer t.destroy();
        try t.trie.set(case[0], case[1]);
        reset(&t.trie.root, true);
        out.* = t.trie.hash();
    }
    for (hashes, 0..) |a, i| for (hashes[i + 1 ..]) |b| try expectDifferent(a, b);
}

test "cached hashes stay equal to freshly calculated ones" {
    const t = try TestTrie.create();
    defer t.destroy();
    var random = std.Random.DefaultPrng.init(1);
    var buf: [16]u8 = undefined;
    for (0..500) |_| {
        const r = random.random();
        const key = try std.fmt.bufPrint(&buf, "{d}:{d}:{d}", .{ r.uintLessThan(u8, 3), r.uintLessThan(u8, 3), r.uintLessThan(u8, 3) });
        if (r.boolean()) try t.trie.set(key, "v") else t.trie.delete(key) catch {};
        const cached = t.trie.hash();
        reset(&t.trie.root, false);
        try std.testing.expectEqual(cached, t.trie.hash());
    }
}
