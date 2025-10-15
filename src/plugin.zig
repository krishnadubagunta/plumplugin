//! `Plugin`: A structure that defines a plugin's metadata and execution function
/// `Plugin` represents an extension module that can hook into the database operations.
///
/// Each plugin has:
/// - A name for identification
/// - A hook type specifying when it should be executed
/// - A function that will be called when the hook triggers
///
/// The plugin's run function receives the operation's key and value as parameters,
/// allowing it to inspect or modify the data being processed.
const hook = @import("hook.zig");
pub const Plugin = struct {
    /// Unique identifier for the plugin
    name: []const u8,
    /// The point in execution where this plugin should be triggered
    hook: hook.HookType,
    /// Function to call when the hook is triggered.
    ///
    /// Parameters:
    ///   - `key`: The key involved in the database operation.
    ///   - `value`: The value involved in the database operation.
    ///
    /// Returns:
    ///   - `void`. This function does not return a value.
    run: *const fn (key: []u8, value: []u8) void,
};
