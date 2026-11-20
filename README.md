zig-fetch
================================================================================
Fetch a file from a URL within the zig build system, e.g.

```zig
const file = b.dependency("fetch", .{
    .url = "https://example.com/v1.0/data.bin",
    .sha256 = "<the file's sha256, 64 hex digits>",
}).namedLazyPath("file");
```

The resulting file is a `LazyPath`, so the fetch is lazy.

Why zig-fetch when there are `build.zig.zon` dependencies?
--------------------------------------------------------------------------------
zon dependencies are file archives that zig automatically unpacks and loads
`build.zig` from (if it exists). This means you can't fetch your URL as a zon
dependency if:

1. it's not an archive,
2. it's an archive but you don't want to unpack it,
3. it's an archive but zig can't unpack it,
4. it's an archive with a `build.zig` file that doesn't work with your project.

In addition, you may not want to use a zon dependency if you only want the file
fetched based on a build step (fixed in zig 0.18 with `std.Build.Step.declareDependency`).

Additional Details
--------------------------------------------------------------------------------
- By default, the resulting filename in the cache is the last segment of the URL's path,
  percent-decoded (`data.bin`). Override the name using the `.name = "myname"` build option.
- The `http_proxy`, `https_proxy` and `all_proxy` environment variables are honored (and their
  uppercase forms; `no_proxy` isn't). Only `http://` and `https://` proxies are supported;
  any other (`socks5://`) is an error. Note that environment variables aren't part of the step's
  cache key.
