const std = @import("std");
const builtin = @import("builtin");
const curl = @import("curl");

var g_stopFunc: *const fn () void = undefined;

pub fn setAbortSignalHandler(stopFunc: fn () void) !void {
    g_stopFunc = &stopFunc;

    if (builtin.os.tag == .windows) {
        const handler_routine = struct {
            fn handler_routine(dwCtrlType: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) void {
                if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
                    g_stopFunc();
                    return std.os.windows.TRUE;
                } else {
                    return std.os.windows.FALSE;
                }
            }
        }.handler_routine;
        try std.os.windows.SetConsoleCtrlHandler(handler_routine, true);
    } else {
        const internal_handler = struct {
            fn internalHandler(sig: c_int) callconv(.c) void {
                if (sig == std.posix.SIG.INT) {
                    g_stopFunc();
                }
            }
        }.internalHandler;
        const act = std.posix.Sigaction{
            .handler = .{ .handler = internal_handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
}

pub const RequestArgs = struct {
    url: []const u8,
    method: curl.Easy.Method,
    body: ?[]u8 = null,
    headers: []const std.http.Header = &[0]std.http.Header{},
    allowed_statuses: ?[]u16 = null,
};

pub const Response = struct {
    status_code: u16,
    body: ?[]u8,
    headers: []std.http.Header,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.body) |body| {
            allocator.free(body);
        }
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        allocator.destroy(self);
    }
};

pub fn makeRequest(allocator: std.mem.Allocator, args: RequestArgs, response: *Response) !void {
    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();

    const c = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer c.deinit();

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const c_str_url = try allocator.dupeZ(u8, args.url);
    defer allocator.free(c_str_url);

    const c_headers = try allocator.alloc([:0]const u8, args.headers.len);
    defer {
        for (c_headers) |header| {
            allocator.free(header);
        }
        allocator.free(c_headers);
    }
    for (args.headers, 0..) |header, i| {
        c_headers[i] = try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ header.name, header.value }, 0);
    }

    const fetch_response = try c.fetch(
        c_str_url,
        .{
            .method = args.method,
            .body = args.body,
            .headers = c_headers,
            .writer = &writer.writer,
        },
    );

    var headers = std.ArrayList(std.http.Header).empty;
    var header_iter = try fetch_response.iterateHeaders(.{});
    while (try header_iter.next()) |header| {
        try headers.append(allocator, std.http.Header{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.get()),
        });
    }

    response.* = .{
        .status_code = @intCast(fetch_response.status_code),
        .body = try writer.toOwnedSlice(),
        .headers = try headers.toOwnedSlice(allocator),
    };

    if (args.allowed_statuses) |statuses| {
        var allowed = false;
        for (statuses) |status| {
            if (fetch_response.status_code == @as(i32, @intCast(status))) {
                allowed = true;
                break;
            }
        }
        if (!allowed) {
            return error.InvalidStatusCode;
        }
    }
}

pub fn openResource(allocator: std.mem.Allocator, file_or_url: []const u8) !void {
    const binary = switch (builtin.os.tag) {
        .windows => "explorer.exe",
        .macos => "open",
        .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .solaris, .illumos, .serenity => "xdg-open",
        else => return error.UnsupportedOS,
    };

    const args = &[_][]const u8{ binary, file_or_url };
    var child = std.process.Child.init(
        args,
        allocator,
    );
    const result = try child.spawnAndWait();
    if (result.Exited != 0) {
        return error.OpenFailed;
    }
}

pub fn dirExists(path: []const u8) !bool {
    _ = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            return err;
        },
    };
    return true;
}

/// Arguments for multi-request
pub const MultiRequestArgs = struct {
    url: []const u8,
    method: curl.Easy.Method = .GET,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &[0]std.http.Header{},
    user_data: ?*anyopaque = null,
};

/// Multi-request context for parallel HTTP requests
pub const MultiRequest = struct {
    allocator: std.mem.Allocator,
    multi: curl.Multi,
    requests: std.ArrayList(*RequestContext),

    const RequestContext = struct {
        allocator: std.mem.Allocator,
        easy: curl.Easy,
        buffer: std.ArrayList(u8),
        url: [:0]const u8,
        user_data: ?*anyopaque,
        ca_bundle: std.array_list.Managed(u8),
        c_headers: ?[][:0]const u8,
        body: ?[]const u8,

        fn writeCallback(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, userdata: *anyopaque) callconv(.c) c_uint {
            const ctx: *RequestContext = @ptrCast(@alignCast(userdata));
            const real_size = size * nmemb;
            const data: [*]const u8 = @ptrCast(ptr);
            ctx.buffer.appendSlice(ctx.allocator, data[0..real_size]) catch return 0;
            return @intCast(real_size);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !MultiRequest {
        const multi = try curl.Multi.init();

        // Limit concurrent connections to avoid overwhelming the server
        _ = curl.libcurl.curl_multi_setopt(multi.multi, curl.libcurl.CURLMOPT_MAXCONNECTS, @as(c_long, 50));
        _ = curl.libcurl.curl_multi_setopt(multi.multi, curl.libcurl.CURLMOPT_MAX_TOTAL_CONNECTIONS, @as(c_long, 50));

        return .{
            .allocator = allocator,
            .multi = multi,
            .requests = std.ArrayList(*RequestContext).empty,
        };
    }

    pub fn deinit(self: *MultiRequest) void {
        for (self.requests.items) |req| {
            self.multi.removeHandle(req.easy.handle) catch {};
            req.easy.deinit();
            req.buffer.deinit(self.allocator);
            req.ca_bundle.deinit();
            self.allocator.free(req.url);
            if (req.c_headers) |hdrs| {
                for (hdrs) |h| {
                    self.allocator.free(h);
                }
                self.allocator.free(hdrs);
            }
            if (req.body) |b| {
                self.allocator.free(b);
            }
            self.allocator.destroy(req);
        }
        self.requests.deinit(self.allocator);
    }

    pub fn addRequest(self: *MultiRequest, args: MultiRequestArgs) !void {
        const ctx = try self.allocator.create(RequestContext);
        errdefer self.allocator.destroy(ctx);

        ctx.allocator = self.allocator;
        ctx.url = try self.allocator.dupeZ(u8, args.url);
        ctx.user_data = args.user_data;
        ctx.buffer = std.ArrayList(u8).empty;
        ctx.ca_bundle = try curl.allocCABundle(self.allocator);
        ctx.c_headers = null;
        ctx.body = null;

        ctx.easy = try curl.Easy.init(.{
            .ca_bundle = ctx.ca_bundle,
        });

        try ctx.easy.setUrl(ctx.url);
        try ctx.easy.setMethod(args.method);

        // Set headers if provided
        if (args.headers.len > 0) {
            ctx.c_headers = try self.allocator.alloc([:0]const u8, args.headers.len);
            for (args.headers, 0..) |header, i| {
                ctx.c_headers.?[i] = try std.fmt.allocPrintSentinel(self.allocator, "{s}: {s}", .{ header.name, header.value }, 0);
            }

            var curl_headers: curl.Easy.Headers = .{};
            for (ctx.c_headers.?) |h| {
                try curl_headers.add(h);
            }
            try ctx.easy.setHeaders(curl_headers);
        }

        // Set body if provided
        if (args.body) |body| {
            ctx.body = try self.allocator.dupe(u8, body);
            try ctx.easy.setPostFields(ctx.body.?);
        }

        try ctx.easy.setWritedata(ctx);
        try ctx.easy.setWritefunction(RequestContext.writeCallback);

        try self.requests.append(self.allocator, ctx);
        try self.multi.addHandle(ctx.easy);
    }

    pub fn perform(self: *MultiRequest) !void {
        var still_running: c_int = 1;
        while (still_running > 0) {
            still_running = try self.multi.perform();
            if (still_running > 0) {
                _ = try self.multi.poll(null, 100);
            }
        }
    }

    pub fn getResults(self: *MultiRequest) ![]MultiResult {
        var results = try self.allocator.alloc(MultiResult, self.requests.items.len);

        for (self.requests.items, 0..) |req, i| {
            results[i] = .{
                .body = if (req.buffer.items.len > 0) try self.allocator.dupe(u8, req.buffer.items) else null,
                .user_data = req.user_data,
            };
        }

        return results;
    }
};

pub const MultiResult = struct {
    body: ?[]u8,
    user_data: ?*anyopaque,

    pub fn deinit(self: *MultiResult, allocator: std.mem.Allocator) void {
        if (self.body) |body| {
            allocator.free(body);
        }
    }
};
