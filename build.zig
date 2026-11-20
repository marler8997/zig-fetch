pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fetch.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(exe);

    {
        const url = b.option([]const u8, "url", "URL of the file for namedLazyPath(\"file\"), needs sha256");
        const sha256 = b.option([]const u8, "sha256", "The file's sha256, in hex: the download must match it");
        const name = b.option([]const u8, "name", "The file's name (default: the last segment of url's path)");
        const timeout = b.option(u32, "timeout", "Seconds without data before the download fails (default 60, 0 for never)");
        b.addNamedLazyPath("file", if (url != null or sha256 != null) fetchFile(
            b,
            exe,
            url orelse std.process.fatal("fetch: sha256 needs url", .{}),
            sha256 orelse std.process.fatal("fetch: url needs sha256", .{}),
            name,
            timeout,
        ) else failingFile(b, "fetch: namedLazyPath(\"file\") needs url and sha256"));
    }

    const test_step = b.step("test", "Build the tool and run its unit tests (the rest are in test/)");
    test_step.dependOn(&exe.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/basename.zig"),
        .target = b.graph.host,
    }) })).step);
}

fn fetchFile(b: *std.Build, exe: *std.Build.Step.Compile, url: []const u8, sha256: []const u8, name_option: ?[]const u8, timeout: ?u32) std.Build.LazyPath {
    const name = if (name_option) |n| n: {
        basename.check(n) catch std.process.fatal("fetch: name '{s}' isn't a file name on every OS", .{n});
        break :n n;
    } else basename.basename(b.allocator, url) catch |e| switch (e) {
        error.InvalidUrl => std.process.fatal("fetch: url '{s}' isn't a URL", .{url}),
        error.NoFileName => std.process.fatal("fetch: url '{s}' doesn't end with a file name, give it a name", .{url}),
        error.BadFileName => std.process.fatal("fetch: url '{s}' ends with a name that isn't a file name on every OS, give it a name", .{url}),
        error.OutOfMemory => @panic("OOM"),
    };
    const run = b.addRunArtifact(exe);
    if (timeout) |t| run.addArgs(&.{ "--timeout", b.fmt("{}", .{t}) });
    run.addArg(url);
    run.addArg(sha256);
    return run.addOutputFileArg2(name, .{});
}

const basename = @import("src/basename.zig");

/// A file that fails the build with `msg` if anything uses it, so an output used without url
/// and sha256 gives a clear error.
fn failingFile(b: *std.Build, msg: []const u8) std.Build.LazyPath {
    const write = b.addWriteFiles();
    write.step.dependOn(&b.addFail(msg).step);
    return write.add("file", "");
}

const std = @import("std");
