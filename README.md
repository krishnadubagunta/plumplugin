# plumplugin

The plugin interface for [PlumCache](https://github.com/krishnadubagunta/plumcache), an in-memory key-value store written in Zig.

This package defines the types shared by PlumCache and its plugins, plus a function that loads a plugin from a dynamic library.

> **Note:** PlumCache currently loads plugins at startup but does not call their hooks. A plugin cannot change how the server behaves yet.

## Requirements

- Zig. `build.zig.zon` declares 0.15.1 as the minimum. PlumCache requires 0.17.1 or later.
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

A plugin is a dynamic library that exports a function named `load`. It returns a pointer to a `Plugin`.

`my_plugin.zig`:

```zig
const std = @import("std");
const plumplugin = @import("plumplugin");
const Plugin = plumplugin.plugin.Plugin;

fn run(key: []u8, value: []u8) void {
    std.debug.print("saved {s} = {s}\n", .{ key, value });
}

const instance: Plugin = .{
    .name = "my_plugin",
    .hook = .AfterSave,
    .run = run,
};

export fn load() *const Plugin {
    return &instance;
}
```

The host keeps the returned pointer, so it must stay valid after `load` returns. Declare the `Plugin` at the top level, as above, not as a local variable.

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

`Plugin` is a regular Zig struct, not an `extern struct`, so Zig does not guarantee its memory layout across separate builds. Build the plugin and the host with the same Zig version and the same version of plumplugin.

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
| `run` | `*const fn (key: []u8, value: []u8) void` | Function to run for that hook. It returns nothing, so it cannot report an error. |

### `hook.HookType`

| Value | Intended to run |
| --- | --- |
| `BeforeGet` | Before reading a key's value. |
| `BeforeSave` | Before saving a key-value pair. |
| `BeforeDelete` | Before deleting a key. |
| `AfterGet` | After reading a key's value. |
| `AfterSave` | After saving a key-value pair. |
| `AfterDelete` | After deleting a key. |

### `loadPlugin(name: []const u8)`

Opens `lib<name>.dylib` or `lib<name>.so`, calls its `load` function and returns the resulting `*const plugin.Plugin`. It prints the library's file name to standard error.

| Error | Cause |
| --- | --- |
| `PluginLoadFailed` | The library could not be opened, or it does not export `load`. |
| `OutOfMemory` | The library's file name could not be allocated. |

The error set also includes `NoSpaceLeft`. The library stays open after loading, and there is no function to unload it.

`loadPlugin` runs code from the library inside the host process, so only load libraries you trust.

## Development

```bash
zig build test
```

## License

[MIT](LICENSE)
