//! This module defines the plugin system for PlumCache.
//!
//! The plugin system enables extensibility through hooks that can intercept and modify
//! database operations at various points in their execution lifecycle. This allows
//! for custom functionality such as validation, transformation, logging, and more,
//! without modifying the core database code.
//!
//! The main components are:
//! - `HookType`: An enumeration of the available interception points
//! - `Plugin`: A structure that defines a plugin's metadata and execution function

/// `HookType` defines the points in the database operation lifecycle where plugins can intercept.
///
/// Each hook type represents a specific moment during data operations:
/// - `Before*` hooks run before an operation is performed, allowing for validation or modification
/// - `After*` hooks run after an operation completes, enabling post-processing or side effects
///
/// This enum-based approach allows for type-safe hook registration and dispatch.
pub const hook = @import("hook.zig");
pub const plugin = @import("plugin.zig");
pub const trie = @import("trie.zig");
pub const atom = @import("atom.zig");
pub const intern = @import("intern.zig");
pub const tokenize = @import("tokenize.zig");
pub const snapshot = @import("snapshot.zig");
pub const Snapshot = snapshot.Snapshot;

pub const PlumTrie = trie.PlumTrie;
pub const Digest = atom.Digest;
pub const PlumAtom = atom.PlumAtom;
pub const PurePlumAtom = atom.PurePlumAtom;
pub const InternPool = intern.InternPool;

/// Change this when the plugin interface or the data structure's behaviour
/// changes in a way that existing plugins must be rebuilt for.
pub const abi_version: u32 = 3;

/// Identifies what a host and a plugin must agree on to share a trie: the
/// interface version, Zig version, build mode and type sizes. `loadPlugin`
/// rejects a library whose value differs. It cannot detect every difference.
pub const fingerprint: u64 = std.hash.Wyhash.hash(0, std.fmt.comptimePrint("{d}|{s}|{s}|{d}|{d}|{d}|{d}", .{
    abi_version,
    builtin.zig_version_string,
    @tagName(builtin.mode),
    @sizeOf(plugin.Plugin),
    @sizeOf(trie.PlumTrie),
    @sizeOf(atom.PlumAtom),
    @sizeOf(intern.InternPool),
}));

/// The symbol under which a plugin library exports its fingerprint.
const fingerprint_symbol = "plumplugin_fingerprint";

const FingerprintFn = *const fn () callconv(.c) u64;
const LoadFn = *const fn () callconv(.c) *const plugin.Plugin;

/// Exports everything `loadPlugin` needs from a plugin library. Use it once:
/// `comptime { plumplugin.exportPlugin(&instance); }`
pub fn exportPlugin(comptime instance: *const plugin.Plugin) void {
    const exports = struct {
        fn load() callconv(.c) *const plugin.Plugin {
            return instance;
        }
        fn pluginFingerprint() callconv(.c) u64 {
            return fingerprint;
        }
    };
    @export(&exports.load, .{ .name = "load" });
    @export(&exports.pluginFingerprint, .{ .name = fingerprint_symbol });
}
const builtin = @import("builtin");
const std = @import("std");
const allocator = std.heap.page_allocator;
const native = builtin.os.tag;

pub fn loadPlugin(name: []const u8) error{ PluginLoadFailed, IncompatiblePlugin, OutOfMemory, NoSpaceLeft }!*const plugin.Plugin {
    const buffer: []u8 = try std.mem.Allocator.alloc(allocator, u8, name.len + 9);
    // Only needed to open the library, which does not keep a reference to the name.
    defer allocator.free(buffer);

    // Construct correct library filename for Linux and macOS
    const lib_full_name = switch (native) {
        .linux => blk: {
            const buf = std.fmt.bufPrint(buffer, "lib{s}.so", .{name}) catch |err| {
                std.debug.print("Failed to format buffer: {}\n", .{err});
                return error.PluginLoadFailed;
            };
            break :blk buf;
        },
        .macos => blk: {
            const buf = std.fmt.bufPrint(buffer, "lib{s}.dylib", .{name}) catch |err| {
                std.debug.print("Failed to format buffer: {}\n", .{err});
                return error.PluginLoadFailed;
            };
            break :blk buf;
        },
        else => return error.UnsupportedOS,
    };

    std.debug.print("Loading system library: {s}\n", .{lib_full_name});

    var lib = std.DynLib.open(lib_full_name) catch |err| {
        std.debug.print("Failed to load library: {}\n", .{err});
        return error.PluginLoadFailed;
    };

    // On success the library stays open, as the plugin's code lives in it.
    errdefer lib.close();

    // Check compatibility before using anything else from the library.
    const fingerprintFn = lib.lookup(FingerprintFn, fingerprint_symbol) orelse {
        std.debug.print("{s} has no fingerprint. Export it with exportPlugin.\n", .{lib_full_name});
        return error.IncompatiblePlugin;
    };
    if (fingerprintFn() != fingerprint) {
        std.debug.print("{s} was built with a different Zig version, build mode or plumplugin.\n", .{lib_full_name});
        return error.IncompatiblePlugin;
    }

    const loadFn = lib.lookup(LoadFn, "load") orelse return error.PluginLoadFailed;

    return loadFn();
}

test {
    _ = trie;
    _ = snapshot;
}

test "a missing library fails to load" {
    try std.testing.expectError(error.PluginLoadFailed, loadPlugin("plumplugin_does_not_exist"));
}
