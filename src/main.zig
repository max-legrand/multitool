const std = @import("std");
const multitool = @import("multitool");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const requestArgs = multitool.RequestArgs{
        .method = .GET,
        .body = null,
        .url = "https://jsonplaceholder.typicode.com/todos/1",
        .headers = &[_]std.http.Header{},
    };
    const result = try allocator.create(multitool.Response);
    defer result.deinit(allocator);
    try multitool.makeRequest(
        allocator,
        requestArgs,
        result,
    );
    std.debug.print("Response body: {s}\n", .{result.body.?});

    std.debug.print("Response headers:\n", .{});
    for (result.headers) |header| {
        std.debug.print("  {s}: {s}\n", .{ header.name, header.value });
    }
}
