//! `InternPool`: reference-counted string interning for the Plum data structure.
//!
//! Each distinct string is stored once. Nodes that share a segment, such as every
//! `name` in `user:1:name` and `user:2:name`, refer to the same bytes. A string is
//! freed when its last user releases it.

const std = @import("std");

/// A set of strings, each with a count of its users.
pub const InternPool = struct {
    /// Maps each string, owned by the pool, to its reference count.
    pool: std.StringHashMap(u32),
    /// Allocates the map and the strings.
    allocator: std.mem.Allocator,

    /// Creates an empty pool.
    pub fn init(allocator: std.mem.Allocator) InternPool {
        return InternPool{
            .pool = std.StringHashMap(u32).init(allocator),
            .allocator = allocator,
        };
    }

    /// Frees all remaining strings and the map.
    ///
    /// Does not free the `InternPool` struct itself.
    pub fn deinit(self: *InternPool) void {
        var keys = self.pool.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.pool.deinit();
    }

    /// Adds one reference to `key` and returns the pool's copy of it.
    ///
    /// The returned slice stays valid until its last reference is released. Match
    /// each call with one `deintern`.
    pub fn intern(self: *InternPool, key: []const u8) ![]const u8 {
        const entry = try self.pool.getOrPut(key);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            errdefer self.pool.removeByPtr(entry.key_ptr);
            entry.key_ptr.* = try self.allocator.dupe(u8, key);
            entry.value_ptr.* = 1;
        }
        // Return the string itself: pointers into the map move when it grows.
        return entry.key_ptr.*;
    }

    /// Releases one reference to `key`, freeing the string when none remain.
    ///
    /// Does nothing if the string is not in the pool.
    pub fn deintern(self: *InternPool, key: []const u8) void {
        const entry = self.pool.getEntry(key) orelse return;
        entry.value_ptr.* -= 1;
        if (entry.value_ptr.* == 0) {
            const owned = entry.key_ptr.*;
            self.pool.removeByPtr(entry.key_ptr);
            self.allocator.free(owned);
        }
    }

    /// Returns a pointer to the map's entry for `key`, or `null`, without changing
    /// its count.
    ///
    /// The pointer is invalidated when the map is modified.
    pub fn get(self: *InternPool, key: []const u8) ?*[]const u8 {
        // Use the hash map's `getKeyPtr` method to retrieve a pointer to the interned string.
        // Returns `null` if the key is not found.
        return self.pool.getKeyPtr(key) orelse null;
    }
};
