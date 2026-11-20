const usage = "usage: fetch [--timeout SECONDS] URL SHA256 OUT";

/// How long a download may go without data, by default: a stalled server, or one that's gone
/// without closing the connection (which TCP alone never notices while only reading).
const default_timeout_seconds = 60;

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) std.debug.panic("fetch leaked memory", .{});
    const gpa = debug_allocator.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();

    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    var timeout_seconds: u32 = default_timeout_seconds;
    var positional: [3][]const u8 = undefined;
    var count: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            if (!std.mem.eql(u8, arg, "--timeout")) errExit("unknown option '{s}'", .{arg});
            const seconds = args.next() orelse errExit("--timeout needs a number of seconds", .{});
            timeout_seconds = std.fmt.parseInt(u32, seconds, 10) catch errExit("--timeout '{s}' isn't a number of seconds", .{seconds});
            continue;
        }
        if (count < positional.len) positional[count] = arg;
        count += 1;
    }
    if (count < positional.len) errExit(usage, .{});
    if (count > positional.len) errExit("too many command-line arguments, expected 3 but got {}", .{count});
    const url, const sha256_hex, const out_path = positional;
    var expected_hash: [32]u8 = undefined;
    // hexToBytes takes fewer digits than fit, so the length is checked first
    if (sha256_hex.len != 64) errExit("SHA256 '{s}' is {} characters, not 64", .{ sha256_hex, sha256_hex.len });
    _ = std.fmt.hexToBytes(&expected_hash, sha256_hex) catch errExit("SHA256 '{s}' is not a hex string", .{sha256_hex});
    const initial_uri = std.Uri.parse(url) catch |e| errExit("URL '{s}' is invalid: {t}", .{ url, e });

    const progress = std.Progress.start(io, .{ .root_name = std.fs.path.basename(out_path) });
    defer progress.end();
    var watched: Watched = .{};
    var timeout: ?std.Io.Future(void) = if (timeout_seconds == 0) null else io.concurrent(watchdog, .{ io, &watched, timeout_seconds, url }) catch |e|
        errExit("starting the timeout failed with {t}", .{e});
    // (canceling waits for it, so it's done with `watched` before main is)
    defer if (timeout) |*t| t.cancel(io);

    // the proxies live as long as the client
    var proxy_arena: std.heap.ArenaAllocator = .init(gpa);
    defer proxy_arena.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var environ = try init.environ.createMap(gpa);
    defer environ.deinit();
    client.initDefaultProxies(proxy_arena.allocator(), &environ) catch |e|
        errExit("setting up a proxy from http_proxy, https_proxy or all_proxy failed with {t}", .{e});

    // Redirects are followed here, not by std: each one is a sign of life for the timeout, and
    // std reads a redirect's body to reuse the connection, where an error panics.
    var location_buf: [8 * 1024]u8 = undefined;
    var location_unused: []u8 = &location_buf;
    var uri = initial_uri;
    var redirects: u8 = 0;
    var req: std.http.Client.Request = undefined;
    var response = while (true) {
        // std ignores a proxy it can't use (socks5://...) and connects directly: not silently
        if (std.mem.eql(u8, uri.scheme, "https"))
            checkUnsupportedEnv(&environ, client.https_proxy, &https_proxy_vars)
        else
            checkUnsupportedEnv(&environ, client.http_proxy, &http_proxy_vars);
        req = client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            // the bytes as the server has them, what `curl -O` saves: not compressed for transfer
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        }) catch |e| errExit("fetch '{f}' failed with {t}", .{ &uri, e });
        watched.alive();
        // a server may compress anyway: it's saved as sent
        req.accept_encoding = @splat(true);
        req.sendBodiless() catch |e| errExit("fetch '{f}' failed with {t}", .{ &req.uri, connectionError(&req, e) });
        watched.alive();
        const hop = req.receiveHead(&.{}) catch |e| errExit("fetch '{f}' failed with {t}", .{ &req.uri, connectionError(&req, e) });
        watched.alive();
        switch (hop.head.status) {
            .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {},
            else => break hop,
        }
        if (redirects == max_redirects) errExit("fetch '{s}' failed: more than {} redirects", .{ url, max_redirects });
        redirects += 1;
        const location = hop.head.location orelse errExit("fetch '{f}' failed: HTTP {d} without a Location", .{ &req.uri, @intFromEnum(hop.head.status) });
        if (location.len > location_unused.len) errExit("fetch '{s}' failed: its redirects' Locations are longer than {} bytes", .{ url, location_buf.len });
        // the next URI points into location_buf, which outlives every request
        @memcpy(location_unused[0..location.len], location);
        uri = req.uri.resolveInPlace(location.len, &location_unused) catch |e|
            errExit("fetch '{f}' failed: it redirects to '{s}', which isn't a URL ({t})", .{ &req.uri, location, e });
        // not reused: its body isn't read
        if (req.connection) |c| c.closing = true;
        req.deinit();
    };
    defer req.deinit();
    const status = response.head.status;
    if (status != .ok) {
        if (status.phrase()) |phrase| errExit("fetch '{f}' failed with HTTP {d} {s}", .{ &req.uri, @intFromEnum(status), phrase });
        errExit("fetch '{f}' failed with HTTP {d}", .{ &req.uri, @intFromEnum(status) });
    }
    // checked against what arrives: std's body reader ends a body cut short by a closed
    // connection as if it were complete (a chunked body's Content-Length doesn't count)
    const expected_len: ?u64 = if (response.head.transfer_encoding == .none) response.head.content_length else null;
    if (expected_len) |l| progress.setEstimatedTotalItems(kib(l));

    // Beside OUT, renamed to it once checked: OUT is never a partial or wrong download. Unique,
    // so runs for the same OUT don't share it.
    const cwd = std.Io.Dir.cwd();
    var random: [8]u8 = undefined;
    io.random(&random);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.{x}.fetching", .{ out_path, &random });
    defer gpa.free(tmp_path);
    var tmp: Tmp = .{
        .io = io,
        .dir = cwd,
        .path = tmp_path,
        .file = cwd.createFile(io, tmp_path, .{ .exclusive = true }) catch |e| errExit("create file '{s}' failed with {t}", .{ tmp_path, e }),
    };
    watched.tmp.store(&tmp, .release);

    // hashed as it's written, not read back: the hashing writer buffers (a body is streamed into
    // its buffer, which can't be empty), so the file writer doesn't need to
    var file_writer = tmp.file.?.writer(io, &.{});
    var hash_buf: [64 * 1024]u8 = undefined;
    var hashed = file_writer.interface.hashed(std.crypto.hash.sha2.Sha256.init(.{}), &hash_buf);
    var transfer_buf: [64]u8 = undefined;
    const body = response.reader(&transfer_buf);
    var len: u64 = 0;
    // a chunk at a time, each a sign of life for the timeout and a step of the progress
    while (true) {
        len += body.stream(&hashed.writer, .limited(hash_buf.len)) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => tmp.fail("fetch '{f}' failed with {t}", .{ &req.uri, response.bodyErr() orelse connectionError(&req, e) }),
            error.WriteFailed => tmp.fail("write file '{s}' failed with {t}", .{ tmp_path, file_writer.err orelse e }),
        };
        watched.alive();
        progress.setCompletedItems(kib(len));
    }
    // the download is done: what's left is the disk's, however long it takes
    if (timeout) |*t| t.cancel(io);
    hashed.writer.flush() catch |e| tmp.fail("write file '{s}' failed with {t}", .{ tmp_path, file_writer.err orelse e });
    if (expected_len) |expected| if (len != expected)
        tmp.fail("fetch '{f}' failed: the connection closed after {} of {} bytes", .{ &req.uri, len, expected });
    const actual_hash = hashed.hasher.finalResult();
    if (!std.mem.eql(u8, &actual_hash, &expected_hash))
        tmp.fail("'{s}' has sha256 {x}, not {s}", .{ url, &actual_hash, sha256_hex });
    // on disk before it's named OUT, which a build caches without checking again
    tmp.file.?.sync(io) catch |e| tmp.fail("sync file '{s}' failed with {t}", .{ tmp_path, e });
    tmp.file.?.close(io);
    tmp.file = null;
    std.Io.Dir.rename(cwd, tmp_path, cwd, out_path, io) catch |e| tmp.fail("rename file '{s}' to '{s}' failed with {t}", .{ tmp_path, out_path, e });
}

/// The download until it's OUT: deleted on any failure.
const Tmp = struct {
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    file: ?std.Io.File,

    fn fail(tmp: *Tmp, comptime fmt: []const u8, args: anytype) noreturn {
        if (tmp.file) |f| f.close(tmp.io);
        tmp.delete();
        errExit(fmt, args);
    }

    fn delete(tmp: *const Tmp) void {
        tmp.dir.deleteFile(tmp.io, tmp.path) catch |e| std.debug.print("fetch: delete '{s}' failed with {t}\n", .{ tmp.path, e });
    }
};

/// What the download shares with its timeout.
const Watched = struct {
    /// Bumped by each step of the request and each chunk of the body.
    activity: std.atomic.Value(u64) = .init(0),
    /// The temp file, once there is one, for the timeout to delete.
    tmp: std.atomic.Value(?*const Tmp) = .init(null),

    fn alive(watched: *Watched) void {
        _ = watched.activity.fetchAdd(1, .monotonic);
    }
};

/// Ends the download if it goes timeout_seconds without activity. A read blocked on a server
/// that's stopped sending (or vanished without closing) never returns, so this exits the
/// process, which ends it.
fn watchdog(io: std.Io, watched: *const Watched, timeout_seconds: u32, url: []const u8) void {
    var seen = watched.activity.load(.monotonic);
    var idle: u32 = 0;
    while (true) {
        io.sleep(.fromSeconds(1), .awake) catch |e| switch (e) {
            error.Canceled => return,
        };
        const now = watched.activity.load(.monotonic);
        if (now != seen) {
            seen = now;
            idle = 0;
            continue;
        }
        idle += 1;
        if (idle < timeout_seconds) continue;
        if (watched.tmp.load(.acquire)) |tmp| tmp.delete();
        errExit("fetch '{s}' failed: no data for {}s", .{ url, timeout_seconds });
    }
}

/// Progress is counted in KiB, rounded up (so a small download isn't 0 of 0), saturated where
/// a usize can't hold it.
fn kib(bytes: u64) usize {
    return std.math.lossyCast(usize, bytes / 1024 + @intFromBool(bytes % 1024 != 0));
}

/// std follows 3 by default, as does this.
const max_redirects = 3;

const http_proxy_vars = [_][]const u8{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" };
const https_proxy_vars = [_][]const u8{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" };

/// The error behind a request's ReadFailed or WriteFailed: the connection's.
fn connectionError(req: *const std.http.Client.Request, err: anyerror) anyerror {
    const connection = req.connection orelse return err;
    return switch (err) {
        error.ReadFailed => connection.getReadError() orelse err,
        error.WriteFailed => connection.stream_writer.err orelse err,
        else => err,
    };
}

/// A proxy environment variable that's set but that std couldn't use.
fn checkUnsupportedEnv(environ: *const std.process.Environ.Map, proxy: ?*std.http.Client.Proxy, names: []const []const u8) void {
    if (proxy != null) return;
    for (names) |name| {
        const value = environ.get(name) orelse continue;
        if (value.len == 0) continue;
        errExit("proxy '{s}' in {s} isn't supported, only http:// and https:// proxies are", .{ value, name });
    }
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fetch: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const std = @import("std");
