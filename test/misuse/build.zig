//! Misuses zig-fetch, each case must fail with a clear error when the build is configured (or,
//! for file_without_options, when the file is used), see ../build.zig. (How the tool handles
//! bad downloads is tested by ../local.zig.)

pub fn build(b: *std.Build) void {
    const case = b.option(Case, "case", "The misuse to make") orelse std.debug.panic("missing -Dcase", .{});
    const sha256 = "01f5b5a6f8b249e2842e74720376ca84ea6e8094c18b5416ec80a2183fc9ef81";
    const file = switch (case) {
        .file_without_options => b.dependency("fetch", .{}).namedLazyPath("file"),
        .url_without_sha256 => b.dependency("fetch", .{ .url = "https://h/a.bin" }).namedLazyPath("file"),
        .sha256_without_url => b.dependency("fetch", .{ .sha256 = sha256 }).namedLazyPath("file"),
        .trailing_slash => b.dependency("fetch", .{ .url = "https://github.com/", .sha256 = sha256 }).namedLazyPath("file"),
        .no_path => b.dependency("fetch", .{ .url = "https://example.com", .sha256 = sha256 }).namedLazyPath("file"),
        .dot_dot => b.dependency("fetch", .{ .url = "https://h/a/..", .sha256 = sha256 }).namedLazyPath("file"),
        .colon => b.dependency("fetch", .{ .url = "https://h/pkg:1.0", .sha256 = sha256 }).namedLazyPath("file"),
        .not_a_url => b.dependency("fetch", .{ .url = "not a url", .sha256 = sha256 }).namedLazyPath("file"),
        .bad_name => b.dependency("fetch", .{ .url = "https://h/a.bin", .sha256 = sha256, .name = "a:b" }).namedLazyPath("file"),
    };
    b.getInstallStep().dependOn(&b.addInstallFile(file, "file").step);
}

pub const Case = enum {
    file_without_options,
    url_without_sha256,
    sha256_without_url,
    trailing_slash,
    no_path,
    dot_dot,
    colon,
    not_a_url,
    bad_name,
};

const std = @import("std");
