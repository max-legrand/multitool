const std = @import("std");
const builtin = @import("builtin");

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
    method: std.http.Method,
    body: ?[]u8,
    headers: []std.http.Header,
};

pub fn makeRequest(allocator: std.mem.Allocator, args: RequestArgs) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(args.url);

    var request = try client.request(args.method, uri, .{});
    defer request.deinit();
    request.extra_headers = args.headers;

    if (args.body) |body| {
        try request.sendBodyComplete(body);
    } else {
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&.{});

    var transfer_buf: [1024 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;

    const reader = response.readerDecompressing(
        &transfer_buf,
        &decompress,
        &decompress_buf,
    );

    const response_body = try reader.allocRemaining(allocator, .unlimited);
    return response_body;
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
