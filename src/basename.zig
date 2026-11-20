//! The name a fetched file gets: the last segment of its URL's path, percent-decoded, if that's
//! a file name every OS takes.

pub const Error = error{
    /// std.Uri can't parse it
    InvalidUrl,
} || NameError;

pub const NameError = error{
    /// its path ends without a name: none, a trailing /, . or ..
    NoFileName,
    /// a name Windows (or every OS) won't take
    BadFileName,
};

pub fn basename(arena: std.mem.Allocator, url: []const u8) (Error || error{OutOfMemory})![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |p| p,
    };
    const segment = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
    const name = try (switch (uri.path) {
        .raw => std.Uri.Component{ .raw = segment },
        .percent_encoded => std.Uri.Component{ .percent_encoded = segment },
    }).toRawMaybeAlloc(arena);
    try check(name);
    return name;
}

/// Whether `name` is a file name every OS takes. Only what some OS can't create is checked
/// (the rest would build on one OS and fail on another): Windows can't create these, Linux
/// can. ("." and ".." are directories everywhere, failing with confusing errors.)
pub fn check(name: []const u8) NameError!void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.NoFileName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.BadFileName;
    for (name) |c| {
        // (a ':' is worse than an error on Windows: the start of a stream name, leaving a file
        // named for what's before it)
        if (c < 0x20 or std.mem.indexOfScalar(u8, "/\\:*?\"<>|", c) != null) return error.BadFileName;
    }
}

fn expectName(expected: []const u8, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(expected, try basename(arena.allocator(), url));
}

fn expectError(expected: Error, url: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(expected, basename(arena.allocator(), url));
}

test "the last path segment" {
    try expectName("data.bin", "https://example.com/v1.0/data.bin");
    try expectName("x", "https://h/x");
}

test "query and fragment aren't part of the name" {
    try expectName("a.bin", "https://h/dir/a.bin?token=1&b=/c.bin");
    try expectName("a.bin", "https://h/a.bin#frag/x");
    try expectName("dl", "https://h/dl?file=x.bin");
}

test "percent-decoded" {
    try expectName("my file.bin", "https://h/my%20file.bin");
    try expectError(error.BadFileName, "https://h/a%2Fb.bin");
    try expectError(error.BadFileName, "https://h/a%00.bin");
}

test "no path, or one that ends without a name" {
    try expectError(error.NoFileName, "https://example.com");
    try expectError(error.NoFileName, "https://example.com?x=1");
    try expectError(error.NoFileName, "https://host:8080");
    try expectError(error.NoFileName, "https://github.com/");
    try expectError(error.NoFileName, "https://h/a/..");
    try expectError(error.NoFileName, "https://h/a/.");
}

test "names Windows won't take" {
    try expectError(error.BadFileName, "https://h/pkg:1.0");
    try expectError(error.BadFileName, "https://h/a%5Cb.bin");
    try expectError(error.BadFileName, "https://h/a*b");
    try expectError(error.BadFileName, "https://h/a%3Fb");
    try expectError(error.BadFileName, "https://h/a%01b");
    try expectError(error.BadFileName, "https://h/a%FF.bin");
    try expectName("é.bin", "https://h/%C3%A9.bin");
}

test "not a URL" {
    try expectError(error.InvalidUrl, "not a url");
}

const std = @import("std");
