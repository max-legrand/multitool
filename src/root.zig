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
