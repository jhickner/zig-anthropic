const std = @import("std");
const anthropic = @import("zig-anthropic");
const Message = anthropic.Message;
const SystemMessage = anthropic.SystemMessage;

// tool definition example
pub const tools = &.{
    .{
        .name = "map_tool",
        .description =
        \\Draw wall segements on a 2d, top-down map at the given coords.
        \\The map is centered on 0,0.
        \\Each coord is a 1x1 segment of wall.
        ,
        .input_schema = .{
            .type = "object",
            .properties = .{
                .coords = .{
                    .type = "array",
                    .description = "a list of coords for wall segments",
                    .items = .{
                        .type = "object",
                        .properties = .{
                            .x = .{
                                .type = "number",
                                .description = "x coordinate",
                            },
                            .y = .{
                                .type = "number",
                                .description = "y coordinate",
                            },
                        },
                        .required = &.{ "x", "y" },
                    },
                },
            },
            .required = &.{"coords"},
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try anthropic.Client.init(allocator, null);
    defer client.deinit();

    const stdin = std.io.getStdIn().reader();
    var buf_reader = std.io.bufferedReader(stdin);
    const reader = buf_reader.reader();

    const stdout = std.io.getStdOut().writer();
    var buf_writer = std.io.bufferedWriter(stdout);
    const writer = buf_writer.writer();

    var buffer: [1024]u8 = undefined;

    var messages = std.ArrayList(Message).init(allocator);
    defer {
        for (messages.items) |msg| allocator.free(msg.content);
        messages.deinit();
    }

    while (true) {
        try writer.writeAll("> ");
        try buf_writer.flush();

        if (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
            if (line.len == 0) continue;
            const user_message = Message.user(try allocator.dupe(u8, line));
            try messages.append(user_message);

            var system: [1]SystemMessage = .{.{ .text = "You are a helpful assistant." }};

            const payload = anthropic.ChatPayload{
                .system = &system,
                .messages = messages.items,
            };

            const res = client.chat(payload, tools) catch continue;
            defer res.deinit();

            var response_buffer = std.ArrayList(u8).init(allocator);
            defer response_buffer.deinit();

            for (res.value.content) |block| {
                if (std.mem.eql(u8, block.type, "text")) {
                    try response_buffer.appendSlice(block.text.?);
                } else if (std.mem.eql(u8, block.type, "tool_use")) {
                    const js = try std.json.stringifyAlloc(allocator, block.input.?, .{});
                    defer allocator.free(js);
                    try response_buffer.appendSlice(js);
                }
            }

            const response = try response_buffer.toOwnedSlice();

            try writer.writeAll(response);
            writer.writeAll("\n") catch unreachable;
            buf_writer.flush() catch unreachable;

            try messages.append(Message.assistant(response));
        } else {
            break; // EOF reached
        }
    }
}
