//! String splitting, used for both command lines and keys.

const std = @import("std");

/// The key segment separator used unless the config sets another.
pub const default_delimiter = ":";

/// Returns an iterator over the non-empty parts of `input`.
///
/// `delimiter` defaults to `default_delimiter`. The iterator refers to
/// `input`, which must outlive it.
///
/// ```
/// var tokens = Tokenize("user:1001:name", null);
/// _ = tokens.next(); // "user"
/// _ = tokens.next(); // "1001"
/// _ = tokens.next(); // "name"
/// ```
pub fn Tokenize(input: []const u8, delimiter: ?[]const u8) std.mem.TokenIterator(u8, .sequence) {
    const d = delimiter orelse default_delimiter;
    const tokens = std.mem.tokenizeSequence(u8, input, d);
    return tokens;
}
