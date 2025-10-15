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
const builtin = @import("builtin");
const std = @import("std");
const allocator = std.heap.page_allocator;
const native = builtin.os.tag;

pub fn loadPlugin(name: []const u8) error{ PluginLoadFailed, OutOfMemory, NoSpaceLeft }!*const plugin.Plugin {
    const buffer: []u8 = try std.mem.Allocator.alloc(allocator, u8, name.len + 9);

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

    const LoadFn = *const fn () *const plugin.Plugin;
    const loadFn = lib.lookup(LoadFn, "load") orelse return error.PluginLoadFailed;

    const pluginInstance = loadFn();

    return pluginInstance;
}
