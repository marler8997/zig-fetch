//! check FILE NAME SHA256: FILE is named NAME and its sha256 is SHA256.

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var args = try init.args.iterateAllocator(arena);
    _ = args.skip();
    const path = args.next().?;
    const name = args.next().?;
    const sha256 = args.next().?;

    if (!std.mem.eql(u8, std.fs.path.basename(path), name)) std.debug.panic("'{s}' isn't named {s}", .{ path, name });
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &got, sha256)) std.debug.panic("'{s}' has sha256 {s}, not {s}", .{ path, &got, sha256 });
}

const std = @import("std");
