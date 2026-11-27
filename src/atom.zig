//! The nodes of the Plum data structure.
//!
//! ```
//! PlumAtom                      a node in the trie
//! ├── pure: PurePlumAtom        the node's own data
//! │   ├── path                  its key segment, interned
//! │   ├── value                 optional value, owned by the atom
//! │   └── access_count, last_accessed, created_at
//! └── children                  segment -> *PlumAtom
//! ```

const std = @import("std");
const intern = @import("intern.zig");

const Sha3 = std.crypto.hash.sha3.Sha3_256;

/// A SHA3-256 hash of a node and everything below it.
pub const Digest = [Sha3.digest_length]u8;

/// Adds `bytes` prefixed with their length, so that neighbouring fields cannot
/// be confused with each other.
fn hashBytes(hasher: *Sha3, bytes: []const u8) void {
    hashInt(hasher, u64, bytes.len);
    hasher.update(bytes);
}

/// Adds an integer in a fixed byte order.
fn hashInt(hasher: *Sha3, comptime T: type, number: T) void {
    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, number, .little);
    hasher.update(&bytes);
}

/// Optional initial access metadata for `PurePlumAtom.init`.
pub const AtomOptions = struct {
    /// Initial access count.
    access_count: i16 = 0,
    /// Initial last-access time in nanoseconds.
    last_accessed: i64 = 0,
};

/// A node with more children than this hashes them in groups.
pub const grouping_threshold = 64;
/// The number of groups. A child's group depends only on its segment.
pub const group_count = 256;

pub fn groupOf(segment: []const u8) usize {
    return @intCast(std.hash.Wyhash.hash(0, segment) % group_count);
}

/// The children of a wide node, split into groups that are hashed separately,
/// so that one change does not rehash every child.
pub const Groups = struct {
    members: [group_count]std.ArrayList(*PlumAtom),
    /// Cached hash of each group, or `null` if it has changed.
    hashes: [group_count]?Digest,
};

/// A node's data without its tree links: segment, value and access metadata.
///
/// The metadata is intended for eviction policies. None is implemented yet.
pub const PurePlumAtom = struct {
    /// The interned key segment, or `null` after `deinit`.
    path: ?[]const u8,
    /// The value, owned by this atom. `null` for a node that is only a path step.
    value: ?[]u8,
    /// Number of `get`s that reached this node. Wraps on overflow.
    access_count: i16,
    /// Wall-clock time of the latest `get`, in nanoseconds. 0 until the first.
    last_accessed: i96,
    /// Wall-clock time the atom was created, in nanoseconds.
    created_at: i96,
    /// When the value was last written, or 0 if it never was. `PlumTrie.set` takes
    /// it from the trie's `Clock`: nanoseconds on the monotonic `.awake` clock,
    /// strictly increasing, and only comparable within one boot.
    modified_at: i96 = 0,

    /// Process context: `gpa` allocates the value, `io` reads the clock.
    __proc: std.process.Init,

    /// Creates an atom with no value, interning `path` in `interner`.
    ///
    /// `options`, if given, sets the initial `access_count` and `last_accessed`.
    pub fn init(proc: std.process.Init, path: []const u8, interner: *intern.InternPool, options: ?AtomOptions) !PurePlumAtom {
        var access_count: i16 = 0;
        var last_accessed: i64 = 0;
        // If options are provided, use them to set initial access metadata.
        if (options) |opt| {
            access_count = opt.access_count;
            last_accessed = opt.last_accessed;
        }
        // Get the current wall-clock time for `created_at`.
        const now = std.Io.Timestamp.now(proc.io, .real);
        // Intern the segment so equal segments share one copy.
        const interned = try interner.intern(path);
        return PurePlumAtom{
            .__proc = proc,
            .path = interned,
            .value = null, // Value is initially null and set later by `setValue`.
            .access_count = access_count,
            .last_accessed = last_accessed,
            .created_at = now.nanoseconds,
        };
    }

    /// Frees the value and releases the segment from `interner`.
    pub fn deinit(self: *PurePlumAtom, interner: *intern.InternPool) void {
        interner.deintern(self.path.?); // De-intern the path.
        self.path = null;
        if (self.value) |value| self.__proc.gpa.free(value);
        self.value = null;
    }

    /// Replaces the value with a copy of `value`.
    ///
    /// The old value is freed only after the copy succeeds, so it is kept if
    /// allocation fails.
    pub fn setValue(self: *PurePlumAtom, value: []const u8) !void {
        // Duplicate first, so the old value survives if allocation fails.
        const copy = try self.__proc.gpa.dupe(u8, value);
        if (self.value) |old| self.__proc.gpa.free(old);
        self.value = copy;
    }

    /// Records an access: increments `access_count` and sets `last_accessed` to now.
    pub fn updateAccessCount(self: *PurePlumAtom) void {
        // Wrapping addition: after the largest i16 value comes the smallest.
        self.access_count = self.access_count +% 1;
        // Update the `last_accessed` timestamp to the current time.
        self.last_accessed = std.Io.Timestamp.now(self.__proc.io, .real).nanoseconds;
    }
};

/// A trie node: a `PurePlumAtom` plus its children.
///
/// A node can hold a value and have children at the same time.
pub const PlumAtom = struct {
    /// This node's segment, value and metadata.
    pure: PurePlumAtom,
    /// Process context. Its `gpa` allocates child nodes.
    __proc: std.process.Init,
    /// Children by segment. Each key is the child's interned `path`, and the map
    /// owns the child nodes.
    children: std.StringHashMap(*PlumAtom),
    /// The result of the last `hash`, or `null` if this node or anything below
    /// it has changed since. `PlumTrie.set` and `PlumTrie.delete` clear it along
    /// the path they change.
    cached_hash: ?Digest = null,
    /// Present while the node has more than `grouping_threshold` children.
    groups: ?*Groups = null,
    /// In a snapshot, the hash this node had when copied. `null` for new nodes.
    origin_hash: ?Digest = null,
    /// In a snapshot, the access count when copied.
    origin_access_count: i16 = 0,
    /// Set by `PlumTrie.get` on every node it passes.
    accessed: bool = false,

    /// Marks the hash as stale. `child` names the child that changed, if any.
    pub fn invalidate(self: *PlumAtom, child: ?[]const u8) void {
        self.cached_hash = null;
        if (self.groups) |groups| {
            if (child) |segment| groups.hashes[groupOf(segment)] = null;
        }
    }

    /// Returns the Merkle hash of this node: a SHA3-256 hash of its segment,
    /// value, `modified_at` and the hashes of its children. Access metadata and
    /// `created_at` are not included.
    ///
    /// Up to `grouping_threshold` children are hashed in segment order. Wider
    /// nodes hash each of their `group_count` groups that way, then combine the
    /// group hashes. Only stale nodes and groups are recalculated. Calculating
    /// reorders the group lists, so it must not run on two threads at once.
    pub fn hash(self: *PlumAtom) Digest {
        if (self.cached_hash) |cached| return cached;

        var hasher = Sha3.init(.{});
        hashBytes(&hasher, self.pure.path.?);
        if (self.pure.value) |value| {
            hashInt(&hasher, u8, 1);
            hashBytes(&hasher, value);
        } else {
            hashInt(&hasher, u8, 0);
        }
        hashInt(&hasher, i96, self.pure.modified_at);

        if (self.groups) |groups| {
            hashInt(&hasher, u8, 1);
            for (&groups.members, &groups.hashes) |*members, *cached| {
                if (cached.* == null) {
                    var group_hasher = Sha3.init(.{});
                    hashChildren(&group_hasher, members.items);
                    cached.* = group_hasher.finalResult();
                }
                hasher.update(&cached.*.?);
            }
        } else {
            hashInt(&hasher, u8, 0);
            var buffer: [grouping_threshold]*PlumAtom = undefined;
            var count: usize = 0;
            var children = self.children.valueIterator();
            while (children.next()) |child| : (count += 1) buffer[count] = child.*;
            hashChildren(&hasher, buffer[0..count]);
        }

        const digest = hasher.finalResult();
        self.cached_hash = digest;
        return digest;
    }

    /// Hashes `children` in segment order, so that their order does not matter.
    fn hashChildren(hasher: *Sha3, children: []*PlumAtom) void {
        std.mem.sort(*PlumAtom, children, {}, lessBySegment);
        hashInt(hasher, u64, children.len);
        for (children) |child| {
            const child_hash = child.hash();
            hasher.update(&child_hash);
        }
    }

    fn lessBySegment(_: void, a: *PlumAtom, b: *PlumAtom) bool {
        return std.mem.lessThan(u8, a.pure.path.?, b.pure.path.?);
    }

    /// Creates a node for the segment `key`, with no value and no children.
    pub fn init(
        mainInit: std.process.Init,
        key: []const u8,
        interner: *intern.InternPool,
    ) !PlumAtom {
        // Initialize an empty hash map for children using the provided allocator.
        const children = std.StringHashMap(*PlumAtom).init(mainInit.gpa);

        return PlumAtom{
            // Initialize the embedded `PurePlumAtom` with the given key and no initial options.
            .pure = try PurePlumAtom.init(mainInit, key, interner, null),
            .__proc = mainInit,
            .children = children,
        };
    }

    /// Frees all descendants, then this node's map, value and segment.
    ///
    /// Does not free the `PlumAtom` itself. For a heap-allocated node, the caller
    /// must then destroy it.
    pub fn deinit(self: *PlumAtom, interner: *intern.InternPool) void {
        // Recursively deinitialize and destroy every child `PlumAtom`.
        var children = self.children.valueIterator();
        while (children.next()) |child| {
            child.*.deinit(interner);
            self.__proc.gpa.destroy(child.*);
        }
        // Deinitialize the hash map used for children, freeing its internal memory.
        self.children.deinit();
        self.freeGroups();
        // Release this atom's path and value.
        self.pure.deinit(interner);
    }

    /// Creates a child for the segment `key` and returns it.
    ///
    /// The segment must not already have a child. Check with `findChild` first.
    pub fn addChild(self: *PlumAtom, key: []const u8, interner: *intern.InternPool) !*PlumAtom {
        // Allocate memory for the new child `PlumAtom` struct.
        const child = try self.__proc.gpa.create(PlumAtom);
        errdefer self.__proc.gpa.destroy(child);
        // Initialize the newly allocated child `PlumAtom` with the given key.
        child.* = try PlumAtom.init(self.__proc, key, interner);
        errdefer child.deinit(interner);
        // Insert the new child into the `children` hash map of the current atom.
        // The key for the hash map is the interned path of the child's `PurePlumAtom`.
        try self.children.put(child.pure.path.?, child);
        errdefer _ = self.children.remove(child.pure.path.?);

        if (self.groups) |groups| {
            try groups.members[groupOf(key)].append(self.__proc.gpa, child);
        } else if (self.children.count() > grouping_threshold) {
            try self.buildGroups();
        }
        self.invalidate(key);
        return child;
    }

    /// Unlinks and returns the child for `key`, or `null`. The caller must
    /// `deinit` and destroy it.
    pub fn removeChild(self: *PlumAtom, key: []const u8) ?*PlumAtom {
        const removed = self.children.fetchRemove(key) orelse return null;
        if (self.groups) |groups| {
            if (self.children.count() <= grouping_threshold) {
                self.freeGroups();
            } else {
                const members = &groups.members[groupOf(key)];
                for (members.items, 0..) |member, i| {
                    if (member == removed.value) {
                        _ = members.swapRemove(i);
                        break;
                    }
                }
            }
        }
        self.invalidate(key);
        return removed.value;
    }

    fn buildGroups(self: *PlumAtom) error{OutOfMemory}!void {
        const groups = try self.__proc.gpa.create(Groups);
        groups.* = .{ .members = @splat(.empty), .hashes = @splat(null) };
        self.groups = groups;
        errdefer self.freeGroups();
        var children = self.children.valueIterator();
        while (children.next()) |child| {
            try groups.members[groupOf(child.*.pure.path.?)].append(self.__proc.gpa, child.*);
        }
    }

    fn freeGroups(self: *PlumAtom) void {
        const groups = self.groups orelse return;
        for (&groups.members) |*members| members.deinit(self.__proc.gpa);
        self.__proc.gpa.destroy(groups);
        self.groups = null;
    }

    /// Returns the direct child for the segment `key`, or `null`.
    pub fn findChild(self: *const PlumAtom, key: []const u8) ?*PlumAtom {
        // Use the hash map's `get` method to find the child.
        // The `get` method returns `null` if the key is not found.
        return self.children.get(key);
    }
};
