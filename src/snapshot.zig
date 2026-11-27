//! Private copies of a trie, and merging their changes back.
//!
//! A snapshot is a deep copy that can be changed on another thread. Merging
//! applies only what changed in the copy, and the latest change wins:
//!
//! - A value written in the copy replaces the live one if it was written later.
//! - A delete, on either side, removes only values written before it.
//! - Reads made with `get` on the copy are added to the live access data.
//!
//! Subtrees whose hash is unchanged since the copy was made hold no changes.
//! Only changes made with `set`, `get` and `delete` are merged reliably.

const std = @import("std");
const atom = @import("atom.zig");
const intern = @import("intern.zig");
const trie_module = @import("trie.zig");
const PlumTrie = trie_module.PlumTrie;

pub const Snapshot = struct {
    /// The copy has its own pool, as pools are not thread-safe.
    pool: intern.InternPool,
    /// The copy. Its changes are what `mergeInto` applies.
    trie: PlumTrie,
    /// Changes in the copy are those timed after this.
    taken_at: i96,

    /// Copies `live`, which starts recording its deletes. Must not run while
    /// `live` is being changed. Takes time and memory proportional to its size.
    pub fn create(live: *PlumTrie) !*Snapshot {
        const gpa = live.__proc.gpa;
        _ = live.hash();

        const self = try gpa.create(Snapshot);
        errdefer gpa.destroy(self);
        self.pool = intern.InternPool.init(gpa);
        errdefer self.pool.deinit();
        self.trie = .{
            .__proc = live.__proc,
            .interner = &self.pool,
            .delimiter = live.delimiter,
            .clock = live.clock,
            .owns_clock = false,
            .record_deletes = true,
            .root = try atom.PlumAtom.init(live.__proc, "", &self.pool),
        };
        errdefer self.trie.deinit();
        try copyNode(&self.trie, &live.root, &self.trie.root);

        self.taken_at = live.clock.next(live.__proc.io);
        live.record_deletes = true;
        return self;
    }

    /// Frees the copy. Must happen before the live trie is freed.
    pub fn destroy(self: *Snapshot) void {
        const gpa = self.trie.__proc.gpa;
        self.trie.deinit();
        self.pool.deinit();
        gpa.destroy(self);
    }

    /// Applies the copy's changes to the trie it was made from. Must not run
    /// while the copy or `live` is being changed. If memory runs out, some
    /// changes may have been applied.
    pub fn mergeInto(self: *Snapshot, live: *PlumTrie) error{OutOfMemory}!void {
        const gpa = live.__proc.gpa;

        var deletions = self.trie.deletions.iterator();
        while (deletions.next()) |entry| {
            try applyDelete(live, entry.key_ptr.*, entry.value_ptr.*);
        }

        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(gpa);
        var root: Cursor = .{ .live = live, .parent = null, .segment = "" };
        try self.mergeNode(&self.trie.root, &root, &path, 0);
    }

    /// `path` is the encoded path of `copy`, and `deleted_at` the latest live
    /// delete of it or of an ancestor.
    fn mergeNode(
        self: *Snapshot,
        copy: *atom.PlumAtom,
        cursor: *Cursor,
        path: *std.ArrayList(u8),
        deleted_at: i96,
    ) error{OutOfMemory}!void {
        if (copy.origin_hash) |origin| {
            if (!copy.accessed and std.mem.eql(u8, &origin, &copy.hash())) return;
        }

        const live = cursor.live;
        if (copy.pure.value) |value| {
            const written = copy.pure.modified_at;
            if (written > self.taken_at and written > deleted_at) {
                const node = try cursor.ensure();
                if (written > node.pure.modified_at) {
                    try node.pure.setValue(value);
                    node.pure.modified_at = written;
                    cursor.invalidate();
                }
            }
        }

        if (copy.accessed) {
            if (cursor.find()) |node| {
                const reads = copy.pure.access_count -% copy.origin_access_count;
                node.pure.access_count +%= reads;
                node.pure.last_accessed = @max(node.pure.last_accessed, copy.pure.last_accessed);
            }
        }

        var children = copy.children.valueIterator();
        while (children.next()) |child| {
            const segment = child.*.pure.path.?;
            const length = path.items.len;
            defer path.shrinkRetainingCapacity(length);
            try trie_module.appendSegment(live.__proc.gpa, path, segment);

            var next: Cursor = .{ .live = live, .parent = cursor, .segment = segment };
            const child_deleted_at = @max(deleted_at, live.deletions.get(path.items) orelse 0);
            try self.mergeNode(child.*, &next, path, child_deleted_at);
        }
    }
};

fn copyNode(copy_trie: *PlumTrie, source: *atom.PlumAtom, copy: *atom.PlumAtom) error{OutOfMemory}!void {
    if (source.pure.value) |value| try copy.pure.setValue(value);
    copy.pure.modified_at = source.pure.modified_at;
    copy.pure.created_at = source.pure.created_at;
    copy.pure.last_accessed = source.pure.last_accessed;
    copy.pure.access_count = source.pure.access_count;
    copy.origin_access_count = source.pure.access_count;

    var children = source.children.valueIterator();
    while (children.next()) |child| {
        const added = try copy.addChild(child.*.pure.path.?, copy_trie.interner);
        try copyNode(copy_trie, child.*, added);
    }

    // Set last, as adding children clears hashes.
    if (source.groups) |groups| copy.groups.?.hashes = groups.hashes;
    copy.cached_hash = source.cached_hash;
    copy.origin_hash = source.cached_hash;
}

/// A position in the live trie that is only created if something is written.
const Cursor = struct {
    live: *PlumTrie,
    parent: ?*Cursor,
    segment: []const u8,

    /// Looked up each time, as merging can add and remove nodes.
    fn find(self: *Cursor) ?*atom.PlumAtom {
        const parent = self.parent orelse return &self.live.root;
        const node = parent.find() orelse return null;
        return node.findChild(self.segment);
    }

    fn ensure(self: *Cursor) error{OutOfMemory}!*atom.PlumAtom {
        const parent = self.parent orelse return &self.live.root;
        const node = try parent.ensure();
        return node.findChild(self.segment) orelse try node.addChild(self.segment, self.live.interner);
    }

    /// Clears the hashes of this node, which must exist, and of its ancestors.
    fn invalidate(self: *Cursor) void {
        self.find().?.invalidate(null);
        var cursor = self;
        while (cursor.parent) |parent| : (cursor = parent) {
            parent.find().?.invalidate(cursor.segment);
        }
    }
};

/// Applies a delete made in a copy at `time` to the live trie.
fn applyDelete(live: *PlumTrie, path: []const u8, time: i96) error{OutOfMemory}!void {
    // Other snapshots still to be merged must lose to this delete too.
    try live.recordDelete(path, time);
    try pruneAt(live, &live.root, path, time);
}

/// Follows `path` below `node`, then prunes what it leads to.
fn pruneAt(live: *PlumTrie, node: *atom.PlumAtom, path: []const u8, time: i96) error{OutOfMemory}!void {
    const length = std.mem.readInt(u32, path[0..4], .little);
    const segment = path[4..][0..length];
    const rest = path[4 + length ..];
    const child = node.findChild(segment) orelse return;

    node.invalidate(segment);
    if (rest.len > 0) return pruneAt(live, child, rest, time);
    if (try prune(live, child, time)) removeAndFree(live, node, segment);
}

/// Removes everything in `node` written before `time`. Returns whether nothing
/// is left, so the node itself should be removed.
fn prune(live: *PlumTrie, node: *atom.PlumAtom, time: i96) error{OutOfMemory}!bool {
    if (node.pure.value) |value| {
        if (node.pure.modified_at < time) {
            live.__proc.gpa.free(value);
            node.pure.value = null;
            node.pure.modified_at = 0;
        }
    }
    node.invalidate(null);

    // Children cannot be removed while iterating over them.
    var empty: std.ArrayList([]const u8) = .empty;
    defer empty.deinit(live.__proc.gpa);
    var children = node.children.valueIterator();
    while (children.next()) |child| {
        const segment = child.*.pure.path.?;
        node.invalidate(segment);
        if (try prune(live, child.*, time)) try empty.append(live.__proc.gpa, segment);
    }
    for (empty.items) |segment| removeAndFree(live, node, segment);

    return node.pure.value == null and node.children.count() == 0;
}

fn removeAndFree(live: *PlumTrie, node: *atom.PlumAtom, segment: []const u8) void {
    const removed = node.removeChild(segment).?;
    removed.deinit(live.interner);
    live.__proc.gpa.destroy(removed);
}

const testing = std.testing;

const Live = struct {
    pool: intern.InternPool,
    trie: PlumTrie,

    fn create() !*Live {
        const self = try testing.allocator.create(Live);
        self.pool = intern.InternPool.init(testing.allocator);
        self.trie = try PlumTrie.init(.{
            .minimal = undefined,
            .arena = undefined,
            .gpa = testing.allocator,
            .io = testing.io,
            .environ_map = undefined,
            .preopens = undefined,
        }, &self.pool, ":");
        return self;
    }

    fn destroy(self: *Live) void {
        self.trie.deinit();
        self.pool.deinit();
        testing.allocator.destroy(self);
    }

    fn expect(self: *Live, key: []const u8, value: []const u8) !void {
        try testing.expectEqualStrings(value, (try self.trie.get(key)).?);
    }

    fn expectGone(self: *Live, key: []const u8) !void {
        try testing.expectError(error.KeyNotFound, self.trie.get(key));
    }
};

test "a copy is independent and has the same hash" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("a:b", "1");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();
    try testing.expectEqual(live.trie.hash(), copy.trie.hash());

    try copy.trie.set("a:b", "2");
    try copy.trie.set("new", "n");

    try live.expect("a:b", "1");
    try live.expectGone("new");
}

test "merging applies a copy's new, changed and deleted keys" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("keep", "k");
    try live.trie.set("change", "old");
    try live.trie.set("drop:child", "d");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try copy.trie.set("change", "new");
    try copy.trie.set("added:deep:key", "a");
    try copy.trie.delete("drop");
    try copy.mergeInto(&live.trie);

    try live.expect("keep", "k");
    try live.expect("change", "new");
    try live.expect("added:deep:key", "a");
    try live.expectGone("drop");
}

test "merging an untouched copy keeps everything the live trie did since" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("a", "old");
    try live.trie.set("b", "b");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try live.trie.set("a", "new");
    try live.trie.delete("b");
    try copy.mergeInto(&live.trie);

    try live.expect("a", "new");
    try live.expectGone("b");
}

test "the later write wins, whichever side made it" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("x", "0");
    try live.trie.set("y", "0");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try copy.trie.set("x", "copy");
    try live.trie.set("x", "live");
    try live.trie.set("y", "live");
    try copy.trie.set("y", "copy");
    try copy.mergeInto(&live.trie);

    try live.expect("x", "live");
    try live.expect("y", "copy");
}

test "writing a value back wins over an earlier live write" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("k", "A");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try live.trie.set("k", "C");
    try copy.trie.set("k", "B");
    try copy.trie.set("k", "A");
    try copy.mergeInto(&live.trie);

    try live.expect("k", "A");
}

test "a later live delete is not undone by an earlier copy write" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("a:b", "0");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try copy.trie.set("a:b", "stale");
    try copy.trie.set("a:c", "stale");
    try live.trie.delete("a");
    try copy.mergeInto(&live.trie);

    try live.expectGone("a:b");
    try live.expectGone("a");
}

test "a copy write after a live delete brings the key back" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("a", "0");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try live.trie.delete("a");
    try copy.trie.set("a", "later");
    try copy.mergeInto(&live.trie);

    try live.expect("a", "later");
}

test "a copy delete removes only what was written before it" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("a", "0");
    try live.trie.set("a:old", "0");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try live.trie.set("a:before", "1");
    try copy.trie.delete("a");
    try live.trie.set("a:after", "2");
    try copy.mergeInto(&live.trie);

    try live.expectGone("a:old");
    try live.expectGone("a:before");
    try live.expect("a:after", "2");
    try testing.expectEqual(null, try live.trie.get("a"));
}

test "a copy can delete a key and write it again" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("a:b", "0");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    try copy.trie.delete("a");
    try copy.trie.set("a:c", "1");
    try copy.mergeInto(&live.trie);

    try live.expectGone("a:b");
    try live.expect("a:c", "1");
}

test "copies merge by time, not by merge order" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("k", "0");
    try live.trie.set("gone", "0");
    const first = try Snapshot.create(&live.trie);
    defer first.destroy();
    const second = try Snapshot.create(&live.trie);
    defer second.destroy();

    try first.trie.set("k", "earlier");
    try first.trie.set("gone", "earlier");
    try second.trie.set("k", "later");
    try second.trie.delete("gone");
    try second.mergeInto(&live.trie);
    try first.mergeInto(&live.trie);

    try live.expect("k", "later");
    try live.expectGone("gone");
}

test "reads made on a copy are added to the live access data" {
    const live = try Live.create();
    defer live.destroy();
    try live.trie.set("k", "v");
    _ = try live.trie.get("k");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();

    _ = try copy.trie.get("k");
    _ = try copy.trie.get("k");
    _ = try live.trie.get("k");
    try copy.mergeInto(&live.trie);

    try testing.expectEqual(4, live.trie.root.findChild("k").?.pure.access_count);
}

test "wide nodes keep correct hashes and merge" {
    const live = try Live.create();
    defer live.destroy();
    var buf: [16]u8 = undefined;
    for (0..1000) |i| try live.trie.set(try std.fmt.bufPrint(&buf, "{d}", .{i}), "v");
    const copy = try Snapshot.create(&live.trie);
    defer copy.destroy();
    try testing.expectEqual(live.trie.hash(), copy.trie.hash());

    try copy.trie.set("7", "changed");
    try copy.trie.delete("8");
    try copy.trie.set("added", "a");
    try copy.mergeInto(&live.trie);

    try live.expect("7", "changed");
    try live.expectGone("8");
    try live.expect("added", "a");
    try live.expect("999", "v");
}

fn expectSameValues(expected: *atom.PlumAtom, actual: ?*atom.PlumAtom) !void {
    if (expected.pure.value) |value| {
        try testing.expectEqualStrings(value, (actual orelse return error.MissingKey).pure.value orelse return error.MissingValue);
    } else if (actual) |node| {
        try testing.expectEqual(null, node.pure.value);
    }
    var wanted = expected.children.valueIterator();
    while (wanted.next()) |child| {
        try expectSameValues(child.*, if (actual) |node| node.findChild(child.*.pure.path.?) else null);
    }
    const node = actual orelse return;
    var present = node.children.valueIterator();
    while (present.next()) |child| {
        if (expected.findChild(child.*.pure.path.?) == null) try expectNoValues(child.*);
    }
}

fn expectNoValues(node: *atom.PlumAtom) !void {
    try testing.expectEqual(null, node.pure.value);
    var children = node.children.valueIterator();
    while (children.next()) |child| try expectNoValues(child.*);
}

fn clearHashes(node: *atom.PlumAtom) void {
    node.cached_hash = null;
    if (node.groups) |groups| groups.hashes = @splat(null);
    var children = node.children.valueIterator();
    while (children.next()) |child| clearHashes(child.*);
}

test "random changes merge like applying them all in time order" {
    for (0..3000) |seed| {
        errdefer std.debug.print("failing seed: {d}\n", .{seed});
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        const live = try Live.create();
        defer live.destroy();
        const expected = try Live.create();
        defer expected.destroy();

        var copies: [3]*Snapshot = undefined;
        var taken: usize = 0;
        defer for (copies[0..taken]) |copy| copy.destroy();

        var key_buffer: [16]u8 = undefined;
        var value_buffer: [16]u8 = undefined;
        for (0..60) |step| {
            // Take the copies at random points among the changes.
            if (taken < copies.len and (step == 5 or random.uintLessThan(u8, 12) == 0)) {
                copies[taken] = try Snapshot.create(&live.trie);
                taken += 1;
            }
            const depth = random.intRangeAtMost(usize, 1, 3);
            var length: usize = 0;
            for (0..depth) |level| {
                if (level > 0) {
                    key_buffer[length] = ':';
                    length += 1;
                }
                key_buffer[length] = 'a' + random.uintLessThan(u8, 3);
                length += 1;
            }
            const key = key_buffer[0..length];
            const side = random.uintAtMost(usize, taken);
            const target = if (side == taken) &live.trie else &copies[side].trie;
            // Copies only see their own changes, as workers do.
            if (random.uintLessThan(u8, 3) == 0) {
                target.delete(key) catch |err| switch (err) {
                    error.KeyNotFound => continue,
                    else => return err,
                };
                expected.trie.delete(key) catch {};
            } else {
                const value = try std.fmt.bufPrint(&value_buffer, "{d}", .{step});
                try target.set(key, value);
                try expected.trie.set(key, value);
            }
        }

        var order = [_]usize{ 0, 1, 2 };
        random.shuffle(usize, &order);
        for (order) |i| {
            if (i < taken) try copies[i].mergeInto(&live.trie);
        }

        try expectSameValues(&expected.trie.root, &live.trie.root);
        const cached = live.trie.hash();
        clearHashes(&live.trie.root);
        try testing.expectEqual(cached, live.trie.hash());
    }
}
