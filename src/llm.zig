const std = @import("std");
const meta = @import("std").meta;
const log = std.log;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const Allocator = std.mem.Allocator;

pub const ChatPayload = struct {
    model: []const u8 = "claude-3-7-sonnet-20250219",
    //model: []const u8 = "claude-3-5-haiku-20241022",
    messages: []Message,
    system: []SystemMessage,
    max_tokens: ?u32 = 4096,
    temperature: ?f32 = 1.0,
};

pub const Usage = struct {
    prompt_tokens: ?u64 = null,
    completion_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
};

pub const Choice = struct {
    index: usize,
    finish_reason: ?[]const u8,
    message: struct { role: []const u8, content: []const u8 },
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    content: []ContentBlock,
    model: []const u8,
    role: []const u8,
    stop_reason: ?[]const u8,
    stop_sequence: ?[]const u8,
    type: []const u8,
    usage: Usage,
};

pub const MessageStart = struct {
    message: struct {
        id: []const u8,
        type: []const u8,
        role: []const u8,
        model: []const u8,
        usage: Usage,
    },
};

pub const ContentBlockStart = struct {
    index: usize,
    content_block: struct {
        type: []const u8,
        text: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
    },
};

pub const Delta = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    partial_json: ?[]const u8 = null,
};

pub const ContentBlockDelta = struct {
    index: usize,
    delta: Delta,
};

pub const ContentBlockStop = struct {
    index: usize,
};

pub const MessageDelta = struct {
    usage: Usage,
};

pub const StreamResponse = union(StreamEvent) {
    message_start: MessageStart,
    content_block_start: ContentBlockStart,
    content_block_delta: ContentBlockDelta,
    content_block_stop: ContentBlockStop,
    message_stop: void,
    message_delta: MessageDelta,
    ping: void,
};

pub const CacheControl = struct {
    type: []const u8 = "ephemeral",
};

pub const SystemMessage = struct {
    type: []const u8 = "text",
    text: []const u8,
    cache_control: CacheControl = .{},
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,

    pub fn user(content: []const u8) Message {
        return .{ .role = "user", .content = content };
    }

    pub fn assistant(content: []const u8) Message {
        return .{ .role = "assistant", .content = content };
    }
};

pub const StreamEvent = enum(u8) {
    message_start,
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_stop,
    message_delta,
    ping,

    pub fn fromString(str: []const u8) ?StreamEvent {
        inline for (std.meta.fields(StreamEvent)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

const StreamReader = struct {
    arena: std.heap.ArenaAllocator,
    request: std.http.Client.Request,
    buffer: [2048]u8 = undefined,

    pub fn init(request: std.http.Client.Request) !StreamReader {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .request = request,
        };
    }

    pub fn deinit(self: *StreamReader) void {
        self.arena.deinit();
        self.request.deinit();
    }

    pub fn next(self: *StreamReader) !?StreamResponse {
        // SSE parser

        // Read "event: " line
        const event_line = (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) orelse return null;
        if (event_line.len == 0) return null;

        // Skip if not an event line
        if (!std.mem.startsWith(u8, event_line, "event: ")) {
            // Skip to next empty line
            while (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) |line| {
                if (line.len == 0) break;
            }
            return null;
        }

        // Extract event name and convert to StreamEvent
        const event_name = event_line["event: ".len..];
        const event_type = StreamEvent.fromString(event_name) orelse {
            // Skip to next empty line if event not recognized
            while (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) |line| {
                if (line.len == 0) break;
            }
            return null;
        };

        // Read "data: " line
        const data_line = (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) orelse return null;
        if (!std.mem.startsWith(u8, data_line, "data: ")) {
            // Skip to next empty line
            while (try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n')) |line| {
                if (line.len == 0) break;
            }
            return null;
        }

        // Extract JSON data
        const data = data_line["data: ".len..];

        // Skip empty line at end of event
        _ = try self.request.reader().readUntilDelimiterOrEof(&self.buffer, '\n');

        // Parse JSON based on event type
        const alloc = self.arena.allocator();
        const parse_opts = std.json.ParseOptions{ .ignore_unknown_fields = true };
        return switch (event_type) {
            .message_start => StreamResponse{
                .message_start = try parseFromSliceLeaky(MessageStart, alloc, data, parse_opts),
            },
            .content_block_start => StreamResponse{
                .content_block_start = try parseFromSliceLeaky(ContentBlockStart, alloc, data, parse_opts),
            },
            .content_block_delta => StreamResponse{
                .content_block_delta = try parseFromSliceLeaky(ContentBlockDelta, alloc, data, parse_opts),
            },
            .content_block_stop => StreamResponse{
                .content_block_stop = try parseFromSliceLeaky(ContentBlockStop, alloc, data, parse_opts),
            },
            .message_delta => StreamResponse{
                .message_delta = try parseFromSliceLeaky(MessageDelta, alloc, data, parse_opts),
            },
            .message_stop => .message_stop,
            .ping => .ping,
        };
    }
};

const LLMError = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    TooManyRequests,
    InternalServerError,
    ServiceUnavailable,
    GatewayTimeout,
    Unknown,
};

fn getError(status: std.http.Status) LLMError {
    return switch (status) {
        .bad_request => LLMError.BadRequest,
        .unauthorized => LLMError.Unauthorized,
        .forbidden => LLMError.Forbidden,
        .not_found => LLMError.NotFound,
        .too_many_requests => LLMError.TooManyRequests,
        .internal_server_error => LLMError.InternalServerError,
        .service_unavailable => LLMError.ServiceUnavailable,
        .gateway_timeout => LLMError.GatewayTimeout,
        else => LLMError.Unknown,
    };
}

pub const Client = struct {
    base_url: []const u8 = "https://api.anthropic.com/v1",
    anthropic_version: []const u8 = "2023-06-01",
    api_key: []const u8,
    allocator: Allocator,
    http_client: std.http.Client,

    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, api_key: ?[]const u8) !Client {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        const _api_key = api_key orelse env.get("ANTHROPIC_API_KEY") orelse return error.MissingAPIKey;
        const duped_api_key = try allocator.dupe(u8, _api_key);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var http_client = std.http.Client{ .allocator = allocator };
        http_client.initDefaultProxies(arena.allocator()) catch |err| {
            http_client.deinit();
            return err;
        };

        return Client{
            .allocator = allocator,
            .api_key = duped_api_key,
            .http_client = http_client,
            .arena = arena,
        };
    }

    fn makeCall(self: *Client, endpoint: []const u8, body: []const u8) !std.http.Client.Request {
        var buf: [16 * 1024]u8 = undefined;

        const path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, endpoint });
        defer self.allocator.free(path);
        const uri = try std.Uri.parse(path);

        var req = try self.http_client.open(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .server_header_buffer = &buf,
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = self.anthropic_version },
            },
        });
        errdefer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        try req.send();
        try req.writeAll(body);
        try req.finish();
        try req.wait();

        return req;
    }

    /// Makes a streaming chat completion request to the Anthropic API.
    /// Returns a StreamReader that can be used to read the response chunks.
    /// Caller must call deinit() on the returned StreamReader when done.
    /// Set tools to `&.{}` if not using tools.
    pub fn streamChat(self: *Client, payload: ChatPayload, tools: anytype) !StreamReader {
        const options = .{
            .system = payload.system,
            .model = payload.model,
            .messages = payload.messages,
            .max_tokens = payload.max_tokens,
            .temperature = payload.temperature,
            .tools = tools,
            .stream = true,
        };
        const body = try std.json.stringifyAlloc(self.allocator, options, .{});
        defer self.allocator.free(body);

        var req = try self.makeCall("/messages", body);

        if (req.response.status != .ok) {
            const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 8);
            defer self.allocator.free(response_body);
            req.deinit();
            log.err("error response: {s}", .{response_body});
            const err = getError(req.response.status);
            return err;
        }

        return StreamReader.init(req);
    }

    /// Makes a chat completion request to the Anthropic API.
    /// Caller owns the returned memory and must call deinit() on the result.
    /// set tools to `&.{}` if not using tools
    pub fn chat(self: *Client, payload: ChatPayload, tools: anytype) !std.json.Parsed(ChatResponse) {
        const options = .{
            .system = payload.system,
            .model = payload.model,
            .messages = payload.messages,
            .max_tokens = payload.max_tokens,
            .temperature = payload.temperature,
            .tools = tools,
        };

        const body = try std.json.stringifyAlloc(self.allocator, options, .{ .emit_null_optional_fields = false });
        defer self.allocator.free(body);

        var req = try self.makeCall("/messages", body);
        defer req.deinit();

        const response = try req.reader().readAllAlloc(self.allocator, 1024 * 8);
        defer self.allocator.free(response);

        if (req.response.status != .ok) {
            log.err("error response: {s}", .{response});
            const err = getError(req.response.status);
            return err;
        }

        const parsed = try std.json.parseFromSlice(
            ChatResponse,
            self.allocator,
            response,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );

        return parsed;
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.api_key);
        self.http_client.deinit();
        self.arena.deinit();
    }
};
