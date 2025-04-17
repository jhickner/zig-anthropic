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

            var response_buffer = std.ArrayList(u8).init(allocator);
            defer response_buffer.deinit();

            // stream uses an internal arena for allocations
            var stream = client.streamChat(payload, tools) catch continue;
            defer stream.deinit();

            // responses will become invalid when stream deinits
            while (try stream.next()) |response| {
                switch (response) {
                    .message_start => {},
                    .content_block_start => |block_start| {
                        if (block_start.content_block.text) |text| {
                            try writer.writeAll(text);
                            try buf_writer.flush();
                            try response_buffer.appendSlice(text);
                        }
                    },
                    .content_block_delta => |block_delta| {
                        if (block_delta.delta.text) |text| {
                            try writer.writeAll(text);
                            try buf_writer.flush();
                            try response_buffer.appendSlice(text);
                        } else if (block_delta.delta.partial_json) |text| {
                            try writer.writeAll(text);
                            try buf_writer.flush();
                            try response_buffer.appendSlice(text);
                        }
                    },
                    .content_block_stop => {},
                    .message_stop => {},
                    .message_delta => {},
                    .ping => {},
                }
            }

            const response = try response_buffer.toOwnedSlice();

            writer.writeAll("\n") catch unreachable;
            buf_writer.flush() catch unreachable;

            try messages.append(Message.assistant(response));
        } else {
            break; // EOF reached
        }
    }
}
