# plumplugin

The plugin interface for [PlumCache](https://github.com/krishnadubagunta/plumcache), an in-memory key-value store written in Zig.

This package defines what PlumCache and its plugins share: the Plum data structure (`PlumTrie`, `PlumAtom`, `PurePlumAtom` and `InternPool`), the plugin interface, and the functions that export and load plugins.

PlumCache runs each plugin on its own worker and passes every hook a snapshot of its trie. For when hooks run and what they may change, see the [PlumCache README](https://github.com/krishnadubagunta/plumcache#plugins).

## Requirements

- Zig 0.17.1 or later
- macOS or Linux

## Installation

From your project folder:

```bash
zig fetch --save git+https://github.com/krishnadubagunta/plumplugin
```

Then, in `build.zig`, import the module into the module that uses it:

```zig
const plumplugin = b.dependency("plumplugin", .{}).module("plumplugin");
lib.root_module.addImport("plumplugin", plumplugin);
```

Here `lib` is your own compile step.

## Writing a plugin

A plugin is a dynamic library that provides one `Plugin`. Call `exportPlugin` once to export it. This adds the `load` function and the compatibility fingerprint that `loadPlugin` checks.

`my_plugin.zig`:

```zig
const std = @import("std");
const plumplugin = @import("plumplugin");
const Plugin = plumplugin.plugin.Plugin;

fn run(_: *plumplugin.PlumTrie, key: []u8, value: []u8) void {
    std.debug.print("saved {s} = {s}\n", .{ key, value });
}

const instance: Plugin = .{
    .name = "my_plugin",
    .hook = .AfterSave,
    .run = run,
};

comptime {
    plumplugin.exportPlugin(&instance);
}
```

The host keeps a pointer to the `Plugin`, so declare it at the top level, as above.

Build it as a dynamic library. In `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const plumplugin = b.dependency("plumplugin", .{}).module("plumplugin");

    const lib = b.addLibrary(.{
        .name = "my_plugin",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("my_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("plumplugin", plumplugin);
    b.installArtifact(lib);
}
```

`zig build` then writes `libmy_plugin.dylib` (macOS) or `libmy_plugin.so` (Linux) to `zig-out/lib`.

A plugin runs its own compiled copy of the trie code on the host's memory. Build both with the same Zig version, plumplugin source and build mode. `loadPlugin` rejects a library whose `fingerprint` differs, which covers `abi_version`, the Zig version, build mode and type sizes. It cannot detect every difference, so increase `abi_version` when a change requires plugins to be rebuilt.

## Using a plugin with PlumCache

Add the plugin's name, without the `lib` prefix or file extension, to one of the lists in PlumCache's config file:

```toml
[plugins.eviction]
srcSet = ["my_plugin"]

[plugins.queue]
srcSet = []
```

The library must be somewhere the system's library search can find it. On macOS, for example:

```bash
DYLD_LIBRARY_PATH=/path/to/my_plugin/zig-out/lib zig build run
```

On Linux, the equivalent variable is `LD_LIBRARY_PATH`.

## API

### `plugin.Plugin`

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | `[]const u8` | Plugin name. |
| `hook` | `hook.HookType` | When the plugin is meant to run. |
| `run` | `*const fn (trie: *PlumTrie, key: []u8, value: []u8) void` | Function to run for that hook. It returns nothing, so it cannot report an error. |

### `hook.HookType`

| Value | Intended to run |
| --- | --- |
| `BeforeGet` | Before reading a key's value. |
| `BeforeSave` | Before saving a key-value pair. |
| `BeforeDelete` | Before deleting a key. |
| `AfterGet` | After reading a key's value. |
| `AfterSave` | After saving a key-value pair. |
| `AfterDelete` | After deleting a key. |

### Data structure

`PlumTrie`, `PlumAtom`, `PurePlumAtom` and `InternPool` are exported from the root module.

`trie.hash()` and `node.hash()` return a SHA3-256 [Merkle hash](https://en.wikipedia.org/wiki/Merkle_tree) covering a node and everything below it: each segment, value and `modified_at`, plus the child hashes in segment order. `created_at`, access data and the delimiter are not included. A write changes the hashes from the written node up to the root, so a branch with an unchanged hash can be skipped. Writing the same value again also changes them, because `modified_at` changes. Hashes are calculated when requested and cached until a `set` or `delete` below them. Nodes with more than 64 children hash them in 256 groups. Hashing a trie is not thread-safe. Keys are split on the trie's delimiter. Change a trie passed to a hook only through its `set` and `delete` methods.

### `Snapshot`

`Snapshot.create(live)` makes a private copy of a trie, which another thread can change. `snapshot.mergeInto(live)` applies its changes: the latest write wins, a delete removes only values written before it, and reads add to the access data. Create and merge on the thread that owns the live trie, and destroy every snapshot before it. After creating a snapshot, the live trie records its deletes; call `forgetDeletions` once no older snapshot remains to be merged. The [PlumCache architecture document](https://github.com/krishnadubagunta/plumcache/blob/main/docs/architecture.md) describes the structure.

### `exportPlugin(instance)`

Exports a `*const plugin.Plugin` known at compile time. Call it in a top-level `comptime` block.

### `loadPlugin(name: []const u8)`

Opens `lib<name>.dylib` or `lib<name>.so`, checks its fingerprint, calls its `load` function and returns the resulting `*const plugin.Plugin`. It prints the library's file name to standard error.

| Error | Cause |
| --- | --- |
| `PluginLoadFailed` | The library could not be opened, or it does not export `load`. |
| `IncompatiblePlugin` | The library has no fingerprint, or its fingerprint differs from the host's. |
| `OutOfMemory` | The library's file name could not be allocated. |

The error set also includes `NoSpaceLeft`. The library stays open after loading, and there is no function to unload it.

`loadPlugin` runs code from the library inside the host process, so only load libraries you trust.

## Development

```bash
zig build test
```

## License

[MIT](LICENSE)
