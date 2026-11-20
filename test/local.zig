//! local FETCH WORK_DIR: runs FETCH against a local HTTP server, one case per response a real
//! server can give (or a way to call fetch), checking its exit code, its message, and what it
//! leaves in the directory: OUT and nothing else on success, nothing on failure.

pub fn main(init: std.process.Init.Minimal) !void {
    // a short-lived process: nothing is freed before it exits
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = init.environ, .argv0 = .init(init.args) });
    const io = threaded.io();

    var args = try init.args.iterateAllocator(arena);
    _ = args.skip();
    const fetch = args.next() orelse std.debug.panic("usage: local FETCH WORK_DIR", .{});
    const work = args.next() orelse std.debug.panic("usage: local FETCH WORK_DIR", .{});

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    _ = try std.Thread.spawn(.{}, serve, .{ io, &server });
    // a port nothing listens on: one that was listened on, then closed
    const closed_port = blk: {
        var closed = try address.listen(io, .{});
        defer closed.deinit(io);
        break :blk closed.socket.address.getPort();
    };

    // the children report their progress to it (and so to the zig build running this)
    const progress = std.Progress.start(io, .{ .root_name = "fetch cases" });
    defer progress.end();

    // the children's environment: no proxies but the ones a case sets
    var environ = try init.environ.createMap(arena);
    for (proxy_vars) |name| _ = environ.swapRemove(name);

    var t: Tester = .{
        .io = io,
        .arena = arena,
        .fetch = fetch,
        .work = work,
        .port = server.socket.address.getPort(),
        .environ = environ,
        .progress = progress,
    };

    // bodies, however they're framed
    t.check("ok", &.{ t.url("/ok"), sha(&body), t.out("ok") }, &.{}, .{ .ok = &body });
    t.check("empty", &.{ t.url("/empty"), sha(""), t.out("empty") }, &.{}, .{ .ok = "" });
    t.check("chunked", &.{ t.url("/chunked"), sha(&body), t.out("chunked") }, &.{}, .{ .ok = &body });
    // a chunked body's Content-Length doesn't count
    t.check("chunked with a wrong Content-Length", &.{ t.url("/chunked-length"), sha(&body), t.out("chunked-length") }, &.{}, .{ .ok = &body });
    t.check("chunked, cut short", &.{ t.url("/chunked-cut"), sha(&body), t.out("chunked-cut") }, &.{}, .{ .fail = "/chunked-cut' failed with HttpChunkTruncated" });
    t.check("chunked, an invalid chunk", &.{ t.url("/chunked-invalid"), sha(&body), t.out("chunked-invalid") }, &.{}, .{ .fail = "/chunked-invalid' failed with HttpChunkTruncated" });
    t.check("until the connection closes", &.{ t.url("/until-close"), sha(&body), t.out("until-close") }, &.{}, .{ .ok = &body });
    // compressed for transfer anyway: saved as sent, not decoded
    t.check("Content-Encoding: gzip", &.{ t.url("/gzip"), sha(&body), t.out("gzip") }, &.{}, .{ .ok = &body });
    // one std can't parse
    t.check("Content-Encoding: br", &.{ t.url("/br"), sha(&body), t.out("br") }, &.{}, .{ .fail = "/br' failed with HttpHeadersInvalid" });
    // the request asks for the bytes as they are (the server echoes its Accept-Encoding)
    t.check("Accept-Encoding: identity", &.{ t.url("/accept-encoding"), sha("identity"), t.out("accept-encoding") }, &.{}, .{ .ok = "identity" });

    // redirects
    // /redirect/N redirects N+1 times (to /redirect/N-1, ..., /redirect/0, then /ok)
    t.check("3 redirects", &.{ t.url("/redirect/2"), sha(&body), t.out("redirect-3") }, &.{}, .{ .ok = &body });
    t.check("4 redirects", &.{ t.url("/redirect/3"), sha(&body), t.out("redirect-4") }, &.{}, .{ .fail = "/redirect/3' failed: more than 3 redirects" });
    // the error names where it was redirected to
    t.check("redirected to a 404", &.{ t.url("/redirect-404"), sha(&body), t.out("redirect-404") }, &.{}, .{ .fail = "/missing' failed with HTTP 404 Not Found" });
    // a redirect's body isn't read, so its connection failing doesn't matter
    t.check("a redirect reset mid-body", &.{ t.url("/redirect-reset"), sha(&body), t.out("redirect-reset") }, &.{}, .{ .ok = &body });
    t.check("redirected to ftp", &.{ t.url("/redirect-ftp"), sha(&body), t.out("redirect-ftp") }, &.{}, .{ .fail = "fetch 'ftp://h/a.bin' failed with UnsupportedUriScheme" });
    t.check("a redirect without a Location", &.{ t.url("/redirect-no-location"), sha(&body), t.out("redirect-no-location") }, &.{}, .{ .fail = "/redirect-no-location' failed: HTTP 302 without a Location" });

    // failures: a clear message, and nothing left behind
    t.check("404", &.{ t.url("/missing"), sha(&body), t.out("404") }, &.{}, .{ .fail = "/missing' failed with HTTP 404 Not Found" });
    t.check("a status without a phrase", &.{ t.url("/status-599"), sha(&body), t.out("599") }, &.{}, .{ .fail = "failed with HTTP 599\n" });
    t.check("cut short", &.{ t.url("/short"), sha(&body), t.out("short") }, &.{}, .{ .fail = "the connection closed after 500 of 1024 bytes" });
    t.check("connection reset", &.{ t.url("/reset"), sha(&body), t.out("reset") }, &.{}, .{ .fail = "/reset' failed with " });
    const refused_url = std.fmt.allocPrint(arena, "http://127.0.0.1:{}/ok", .{closed_port}) catch oom();
    t.check("connection refused", &.{ refused_url, sha(&body), t.out("refused") }, &.{}, .{ .fail = "failed with ConnectionRefused" });
    t.check("wrong sha256", &.{ t.url("/ok"), sha("other"), t.out("wrong-sha256") }, &.{}, .{ .fail = "/ok' has sha256 " ++ sha(&body) });
    t.check("OUT in a missing directory", &.{ t.url("/ok"), sha(&body), t.path("missing-dir", "no/such/dir/out") }, &.{}, .{ .fail = "failed with FileNotFound" });

    // a server that stops sending, or never answers, without closing the connection: TCP never
    // notices, the timeout does
    t.check("stalled mid-body", &.{ "--timeout", "2", t.url("/stall"), sha(&body), t.out("stall") }, &.{}, .{ .fail = "/stall' failed: no data for 2s" });
    t.check("no response", &.{ "--timeout", "2", t.url("/no-response"), sha(&body), t.out("no-response") }, &.{}, .{ .fail = "/no-response' failed: no data for 2s" });
    // 3 seconds without data: too long for 1, not for 0 (never)
    t.check("a pause longer than the timeout", &.{ "--timeout", "1", t.url("/pause"), sha(&body), t.out("pause-1") }, &.{}, .{ .fail = "/pause' failed: no data for 1s" });
    t.check("a pause with no timeout", &.{ "--timeout", "0", t.url("/pause"), sha(&body), t.out("pause-0") }, &.{}, .{ .ok = &body });

    // OUT replaced
    t.dir("existing");
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = t.out("existing"), .data = "old" }) catch |e| std.debug.panic("writing {s}: {t}", .{ t.out("existing"), e });
    t.check("an existing OUT", &.{ t.url("/ok"), sha(&body), t.out("existing") }, &.{}, .{ .ok = &body });

    // two runs for the same OUT at once, slowly: neither sees the other's download
    t.concurrent();

    // proxies
    const proxy = arena.dupe(u8, t.url("")) catch oom();
    t.check("through a proxy", &.{ "http://proxied.invalid/ok", sha(&body), t.out("proxy") }, &.{.{ "http_proxy", proxy }}, .{ .ok = &body });
    t.check("an unsupported proxy", &.{ t.url("/ok"), sha(&body), t.out("socks") }, &.{.{ "http_proxy", "socks5://127.0.0.1:1" }}, .{ .fail = "proxy 'socks5://127.0.0.1:1' in http_proxy isn't supported" });
    // only the URL's scheme's proxy matters
    t.check("an unsupported proxy for another scheme", &.{ t.url("/ok"), sha(&body), t.out("socks-https") }, &.{.{ "https_proxy", "socks5://127.0.0.1:1" }}, .{ .ok = &body });

    // the command line
    t.check("no arguments", &.{}, &.{}, .{ .fail = "usage: fetch [--timeout SECONDS] URL SHA256 OUT" });
    t.check("--timeout without seconds", &.{ t.url("/ok"), sha(&body), t.out("timeout-missing"), "--timeout" }, &.{}, .{ .fail = "--timeout needs a number of seconds" });
    t.check("--timeout that isn't a number", &.{ "--timeout", "soon", t.url("/ok"), sha(&body), t.out("timeout-nan") }, &.{}, .{ .fail = "--timeout 'soon' isn't a number of seconds" });
    t.check("an unknown option", &.{ "--timout", "5", t.url("/ok"), sha(&body), t.out("unknown-option") }, &.{}, .{ .fail = "unknown option '--timout'" });
    t.check("not http", &.{ "ftp://h/a.bin", sha(&body), t.out("not-http") }, &.{}, .{ .fail = "fetch 'ftp://h/a.bin' failed with UnsupportedUriScheme" });
    t.check("too many arguments", &.{ t.url("/ok"), sha(&body), t.out("extra"), "x" }, &.{}, .{ .fail = "too many command-line arguments, expected 3 but got 4" });
    t.check("a short SHA256", &.{ t.url("/ok"), sha(&body)[1..], t.out("short-sha") }, &.{}, .{ .fail = "is 63 characters, not 64" });
    t.check("a SHA256 that isn't hex", &.{ t.url("/ok"), "z" ++ sha(&body)[1..], t.out("hex-sha") }, &.{}, .{ .fail = "is not a hex string" });
    t.check("not a URL", &.{ "not a url", sha(&body), t.out("not-url") }, &.{}, .{ .fail = "URL 'not a url' is invalid" });

    // silent when it passes
    if (t.failures > 0) {
        std.debug.print("{} of {} cases failed\n", .{ t.failures, t.cases });
        std.process.exit(1);
    }
}

const proxy_vars = [_][]const u8{ "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" };

/// What the server sends: 1024 bytes.
const body = blk: {
    @setEvalBranchQuota(10_000);
    var b: [1024]u8 = undefined;
    for (&b, 0..) |*c, i| c.* = @truncate(i * 7);
    break :blk b;
};

fn sha(comptime content: []const u8) *const [64]u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        break :blk &hex;
    };
}

const Expect = union(enum) {
    /// exits 0, OUT has this, nothing else is left
    ok: []const u8,
    /// exits 1, its message has this, nothing is left
    fail: []const u8,
};

const Tester = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    fetch: []const u8,
    work: []const u8,
    port: u16,
    environ: std.process.Environ.Map,
    progress: std.Progress.Node,
    cases: usize = 0,
    failures: usize = 0,

    fn url(t: *Tester, path_: []const u8) []const u8 {
        return std.fmt.allocPrint(t.arena, "http://127.0.0.1:{}{s}", .{ t.port, path_ }) catch oom();
    }

    /// OUT for a case: its own directory's file "out"
    fn out(t: *Tester, case: []const u8) []const u8 {
        return t.path(case, "out");
    }

    fn path(t: *Tester, case: []const u8, sub: []const u8) []const u8 {
        return std.fs.path.join(t.arena, &.{ t.work, case, sub }) catch oom();
    }

    fn dir(t: *Tester, case: []const u8) void {
        const p = std.fs.path.join(t.arena, &.{ t.work, case }) catch oom();
        std.Io.Dir.cwd().createDirPath(t.io, p) catch |e| std.debug.panic("creating {s}: {t}", .{ p, e });
    }

    fn run(t: *Tester, args: []const []const u8, env: []const [2][]const u8) std.process.RunResult {
        var environ = t.environ.clone(t.arena) catch oom();
        for (env) |kv| environ.put(kv[0], kv[1]) catch oom();
        const argv = std.mem.concat(t.arena, []const u8, &.{ &.{t.fetch}, args }) catch oom();
        return std.process.run(t.arena, t.io, .{ .argv = argv, .environ_map = &environ, .progress_node = t.progress }) catch |e| std.debug.panic("running {s}: {t}", .{ t.fetch, e });
    }

    fn check(t: *Tester, name: []const u8, args: []const []const u8, env: []const [2][]const u8, expect: Expect) void {
        t.cases += 1;
        // OUT is the argument in WORK; the case's directory is its first directory there (or
        // one of its own when there's no OUT)
        const out_path: ?[]const u8 = for (args) |a| {
            if (std.mem.startsWith(u8, a, t.work)) break a;
        } else null;
        const case_dir = if (out_path) |o| std.fs.path.dirname(o).? else std.fs.path.join(t.arena, &.{ t.work, "args" }) catch oom();
        const root = caseRoot(t.work, case_dir);
        std.Io.Dir.cwd().createDirPath(t.io, root) catch |e| std.debug.panic("creating {s}: {t}", .{ root, e });
        const result = t.run(args, env);
        const code: ?u8 = switch (result.term) {
            .exited => |c| c,
            else => null,
        };
        if (t.verify(result, code, root, out_path, expect)) |problem| {
            t.failures += 1;
            std.debug.print("FAIL {s}: {s}\n  exit: {?}\n  stderr: {s}\n", .{ name, problem, code, result.stderr });
        }
    }

    /// What's wrong with how a case went, if anything.
    fn verify(t: *Tester, result: std.process.RunResult, code: ?u8, root: []const u8, out_path: ?[]const u8, expect: Expect) ?[]const u8 {
        if (std.mem.indexOf(u8, result.stderr, "panic") != null) return "it panicked";
        switch (expect) {
            .ok => |content| {
                if (code != 0) return "it failed";
                if (result.stderr.len != 0) return "it printed something";
                const got = std.Io.Dir.cwd().readFileAlloc(t.io, out_path.?, t.arena, .unlimited) catch return "OUT can't be read";
                if (!std.mem.eql(u8, got, content)) return "OUT has the wrong content";
                const left = t.leftovers(root);
                if (left.len != 1 or !std.mem.eql(u8, left[0], std.fs.path.basename(out_path.?)))
                    return std.fmt.allocPrint(t.arena, "it left {s} (only OUT should be there)", .{std.mem.join(t.arena, ", ", left) catch oom()}) catch oom();
            },
            .fail => |message| {
                if (code != 1) return "it didn't exit 1";
                if (std.mem.indexOf(u8, result.stderr, message) == null)
                    return std.fmt.allocPrint(t.arena, "the message doesn't have '{s}'", .{message}) catch oom();
                const left = t.leftovers(root);
                if (left.len != 0)
                    return std.fmt.allocPrint(t.arena, "it left {s}", .{std.mem.join(t.arena, ", ", left) catch oom()}) catch oom();
            },
        }
        return null;
    }

    /// The files in a case's directory, its subdirectories included.
    fn leftovers(t: *Tester, root: []const u8) []const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var d = std.Io.Dir.cwd().openDir(t.io, root, .{ .iterate = true }) catch return &.{};
        defer d.close(t.io);
        var walker = d.walk(t.arena) catch oom();
        while (walker.next(t.io) catch |e| std.debug.panic("listing {s}: {t}", .{ root, e })) |entry| {
            if (entry.kind != .directory) list.append(t.arena, t.arena.dupe(u8, entry.path) catch oom()) catch oom();
        }
        return list.items;
    }

    /// Two fetches of a slow response to the same OUT at once: both succeed, OUT is right.
    fn concurrent(t: *Tester) void {
        t.cases += 1;
        const name = "two at once for the same OUT";
        t.dir("concurrent");
        const args: []const []const u8 = &.{ t.url("/slow"), sha(&body), t.out("concurrent") };
        var results: [2]std.process.RunResult = undefined;
        var threads: [2]std.Thread = undefined;
        for (&threads, &results) |*thread, *result| {
            thread.* = std.Thread.spawn(.{}, struct {
                fn f(tt: *Tester, a: []const []const u8, r: *std.process.RunResult) void {
                    r.* = tt.run(a, &.{});
                }
            }.f, .{ t, args, result }) catch |e| std.debug.panic("spawning a thread: {t}", .{e});
        }
        for (threads) |thread| thread.join();
        for (results) |result| {
            const code: ?u8 = switch (result.term) {
                .exited => |c| c,
                else => null,
            };
            if (t.verify(result, code, caseRoot(t.work, std.fs.path.dirname(args[2]).?), args[2], .{ .ok = &body })) |problem| {
                t.failures += 1;
                std.debug.print("FAIL {s}: {s}\n  exit: {?}\n  stderr: {s}\n", .{ name, problem, code, result.stderr });
                return;
            }
        }
    }
};

/// A case's own directory under WORK (OUT may be deeper, in directories that don't exist).
fn caseRoot(work: []const u8, case_dir: []const u8) []const u8 {
    const rest = std.mem.trimStart(u8, case_dir[work.len..], "/\\");
    const end = std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len;
    return case_dir[0 .. case_dir.len - rest.len + end];
}

fn oom() noreturn {
    @panic("out of memory");
}

// ---- the server ----

fn serve(io: std.Io, server: *std.Io.net.Server) void {
    while (true) {
        const stream = server.accept(io) catch |e| std.debug.panic("accept: {t}", .{e});
        const thread = std.Thread.spawn(.{}, respond, .{ io, stream }) catch |e| std.debug.panic("spawning a thread: {t}", .{e});
        thread.detach();
    }
}

fn respond(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    // Small: what the resets need (see below), less than a request (fetch's is 79 bytes or more,
    // its Host and User-Agent lines included), so some of it stays unread in the kernel. Every
    // line read fits.
    var read_buf: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    // "GET TARGET HTTP/1.1", TARGET a whole URL when it came through a proxy
    var target_buf: [256]u8 = undefined;
    const request_line = std.mem.trimEnd(u8, r.takeDelimiterInclusive('\n') catch return, "\r\n");
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    _ = parts.next();
    var target = parts.next() orelse return;
    if (std.mem.startsWith(u8, target, "http://")) target = target[(std.mem.indexOfScalarPos(u8, target, "http://".len, '/') orelse return)..];
    const path_ = target_buf[0..target.len];
    @memcpy(path_, target);

    if (std.mem.eql(u8, path_, "/reset") or std.mem.eql(u8, path_, "/redirect-reset")) {
        // half the body, then closed with the request's headers unread: every TCP stack resets
        // (RST) a connection closed with data it hasn't read, rather than ending it (FIN), so
        // fetch gets a read error, not the end of the body
        if (std.mem.eql(u8, path_, "/reset"))
            w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return
        else
            w.print("HTTP/1.1 302 Found\r\nLocation: /ok\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;
        w.writeAll(body[0..500]) catch return;
        w.flush() catch return;
        return;
    }
    // the connection kept open, silent: half the body then nothing, or nothing at all
    if (std.mem.eql(u8, path_, "/stall") or std.mem.eql(u8, path_, "/no-response")) {
        if (std.mem.eql(u8, path_, "/stall")) {
            w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;
            w.writeAll(body[0..500]) catch return;
            w.flush() catch return;
        }
        while (true) io.sleep(.fromSeconds(3600), .awake) catch {};
    }

    var accept_buf: [64]u8 = undefined;
    var accept_encoding: []const u8 = "";
    while (true) {
        const line = std.mem.trimEnd(u8, r.takeDelimiterInclusive('\n') catch return, "\r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "accept-encoding:")) {
            const v = std.mem.trim(u8, line["accept-encoding:".len..], " ");
            accept_encoding = accept_buf[0..v.len];
            @memcpy(accept_buf[0..v.len], v);
        }
    }

    send(io, w, path_, accept_encoding) catch {};
}

const Route = enum {
    ok,
    empty,
    chunked,
    chunked_length,
    chunked_cut,
    chunked_invalid,
    until_close,
    gzip,
    br,
    accept_encoding,
    redirect_404,
    redirect_ftp,
    redirect_no_location,
    status_599,
    short,
    slow,
    pause,
};

const routes: std.StaticStringMap(Route) = .initComptime(.{
    .{ "/ok", .ok },
    .{ "/empty", .empty },
    .{ "/chunked", .chunked },
    .{ "/chunked-length", .chunked_length },
    .{ "/chunked-cut", .chunked_cut },
    .{ "/chunked-invalid", .chunked_invalid },
    .{ "/until-close", .until_close },
    .{ "/gzip", .gzip },
    .{ "/br", .br },
    .{ "/accept-encoding", .accept_encoding },
    .{ "/redirect-404", .redirect_404 },
    .{ "/redirect-ftp", .redirect_ftp },
    .{ "/redirect-no-location", .redirect_no_location },
    .{ "/status-599", .status_599 },
    .{ "/short", .short },
    .{ "/slow", .slow },
    .{ "/pause", .pause },
});

fn send(io: std.Io, w: *std.Io.Writer, path_: []const u8, accept_encoding: []const u8) !void {
    // /redirect/N: to /redirect/N-1, /redirect/0 to /ok
    if (std.mem.startsWith(u8, path_, "/redirect/")) {
        const n = std.fmt.parseInt(u32, path_["/redirect/".len..], 10) catch 0;
        if (n == 0)
            try w.writeAll("HTTP/1.1 302 Found\r\nLocation: /ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        else
            try w.print("HTTP/1.1 302 Found\r\nLocation: /redirect/{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{n - 1});
        return w.flush();
    }
    const route = routes.get(path_) orelse {
        try w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return w.flush();
    };
    switch (route) {
        .ok => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len});
            try w.writeAll(&body);
        },
        .empty => try w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
        .chunked, .chunked_length => {
            try w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n");
            if (route == .chunked_length) try w.writeAll("Content-Length: 99999\r\n");
            try w.writeAll("\r\n");
            var i: usize = 0;
            while (i < body.len) : (i += 100) {
                const chunk = body[i..@min(i + 100, body.len)];
                try w.print("{x}\r\n", .{chunk.len});
                try w.writeAll(chunk);
                try w.writeAll("\r\n");
            }
            try w.writeAll("0\r\n\r\n");
        },
        // a chunk, then closed before the last one
        .chunked_cut => try w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nabcd\r\n"),
        // a chunk size that isn't hex
        .chunked_invalid => try w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nzz\r\nabcd\r\n0\r\n\r\n"),
        .until_close => {
            try w.writeAll("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
            try w.writeAll(&body);
        },
        .gzip => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len});
            try w.writeAll(&body);
        },
        .br => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len});
            try w.writeAll(&body);
        },
        .accept_encoding => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{accept_encoding.len});
            try w.writeAll(accept_encoding);
        },
        .redirect_404 => try w.writeAll("HTTP/1.1 302 Found\r\nLocation: /missing\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
        .redirect_ftp => try w.writeAll("HTTP/1.1 302 Found\r\nLocation: ftp://h/a.bin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
        .redirect_no_location => try w.writeAll("HTTP/1.1 302 Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
        .status_599 => try w.writeAll("HTTP/1.1 599 Custom\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
        .short => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len});
            try w.writeAll(body[0..500]);
        },
        .slow => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len});
            var i: usize = 0;
            while (i < body.len) : (i += 128) {
                try w.writeAll(body[i .. i + 128]);
                try w.flush();
                io.sleep(.fromMilliseconds(30), .awake) catch {};
            }
        },
        // half the body, 3 seconds of nothing, the rest
        .pause => {
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{body.len});
            try w.writeAll(body[0..500]);
            try w.flush();
            io.sleep(.fromSeconds(3), .awake) catch {};
            try w.writeAll(body[500..]);
        },
    }
    try w.flush();
}

const std = @import("std");
