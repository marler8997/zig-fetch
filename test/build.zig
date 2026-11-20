//! Tests the options as a package depending on zig-fetch would use them, and the tool against
//! a local server.

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run the tests");

    // real downloads: fetched files, checked again by a program of its own (name, sha256)
    const check_exe = b.addExecutable(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("check.zig"),
            .target = b.graph.host,
        }),
    });
    {
        // named after the URL (with a timeout, so that option is used too)
        const check = b.addRunArtifact(check_exe);
        check.addFileArg(b.dependency("fetch", .{ .url = msvcrt_url, .sha256 = msvcrt_sha256, .timeout = @as(u32, 120) }).namedLazyPath("file"));
        check.addArgs(&.{ "msvcrt.dll", msvcrt_sha256 });
        test_step.dependOn(&check.step);
    }
    {
        // named by name
        const check = b.addRunArtifact(check_exe);
        check.addFileArg(b.dependency("fetch", .{ .url = msvcrt_url, .sha256 = msvcrt_sha256, .name = "renamed.bin" }).namedLazyPath("file"));
        check.addArgs(&.{ "renamed.bin", msvcrt_sha256 });
        test_step.dependOn(&check.step);
    }

    // the tool against a local server, each response a server can give, see local.zig
    const local = b.addRunArtifact(b.addExecutable(.{
        .name = "local",
        .root_module = b.createModule(.{
            .root_source_file = b.path("local.zig"),
            .target = b.graph.host,
        }),
    }));
    local.addArtifactArg(b.dependency("fetch", .{}).artifact("fetch"));
    _ = local.addOutputDirectoryArg("work");
    test_step.dependOn(&local.step);

    // misuses fail with a clear error, see misuse/build.zig
    for ([_]struct { []const u8, []const u8 }{
        .{ "file_without_options", "namedLazyPath(\"file\") needs url and sha256" },
        .{ "url_without_sha256", "url needs sha256" },
        .{ "sha256_without_url", "sha256 needs url" },
        .{ "trailing_slash", "doesn't end with a file name" },
        .{ "no_path", "doesn't end with a file name" },
        .{ "dot_dot", "doesn't end with a file name" },
        .{ "colon", "ends with a name that isn't a file name on every OS" },
        .{ "not_a_url", "isn't a URL" },
        .{ "bad_name", "name 'a:b' isn't a file name on every OS" },
    }) |case| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("-Dcase={s}", .{case[0]}) });
        run.setName(b.fmt("misuse {s}", .{case[0]}));
        run.setCwd(b.path("misuse"));
        // its inputs, zig-fetch included, aren't args this step can hash
        run.has_side_effects = true;
        run.expectExitCode(1);
        run.expectStdErrMatch(case[1]);
        test_step.dependOn(&run.step);
    }
}

/// A pinned release asset.
const msvcrt_url = "https://github.com/encounter/winedll/releases/download/2026-07-10/msvcrt.dll";
const msvcrt_sha256 = "01f5b5a6f8b249e2842e74720376ca84ea6e8094c18b5416ec80a2183fc9ef81";

const std = @import("std");
