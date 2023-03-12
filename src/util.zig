const std = @import("std");
const libpcre = @import("libpcre");
const main = @import("root");

pub fn unsafeHTML(data: []const u8) UnsafeHTMLPrinter {
    return UnsafeHTMLPrinter{ .data = data };
}

pub const UnsafeHTMLPrinter = struct {
    data: []const u8,

    const Self = @This();

    pub fn format(
        value: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try encodeForHTML(writer, value.data);
    }
};

fn encodeForHTML(writer: anytype, in: []const u8) !void {
    for (in) |char| {
        _ = switch (char) {
            '&' => try writer.write("&amp;"),
            '<' => try writer.write("&lt;"),
            '>' => try writer.write("&gt;"),
            '"' => try writer.write("&quot;"),
            '\'' => try writer.write("&#x27;"),
            '\\' => try writer.write("&#92;"),
            else => try writer.writeByte(char),
        };
    }
}

pub const MatchList = std.ArrayList([]?libpcre.Capture);

pub fn captureWithCallback(
    regex: libpcre.Regex,
    full_string: []const u8,
    options: libpcre.Options,
    allocator: std.mem.Allocator,
    comptime ContextT: type,
    ctx: *ContextT,
    comptime callback: fn (
        ctx: *ContextT,
        full_string: []const u8,
        capture: []?libpcre.Capture,
    ) anyerror!void,
) anyerror!void {
    var offset: usize = 0;

    var match_list = MatchList.init(allocator);
    errdefer match_list.deinit();
    while (true) {
        var maybe_single_capture = try regex.captures(
            allocator,
            full_string[offset..],
            options,
        );
        if (maybe_single_capture) |single_capture| {
            defer allocator.free(single_capture);

            const first_group = single_capture[0].?;
            for (single_capture, 0..) |maybe_group, idx| {
                if (maybe_group != null) {
                    // convert from relative offsets to absolute file offsets
                    single_capture[idx].?.start += offset;
                    single_capture[idx].?.end += offset;
                }
            }

            try callback(ctx, full_string, single_capture);
            offset += first_group.end;
        } else {
            break;
        }
    }
}

pub fn WebPathPrinter(comptime ArgsT: anytype, comptime fmt: []const u8) type {
    return struct {
        ctx: main.Context,
        comptime innerFmt: []const u8 = fmt,
        args: ArgsT,

        const Self = @This();

        pub fn format(
            self: Self,
            comptime outerFmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = outerFmt;
            _ = options;
            try std.fmt.format(writer, "{s}", .{
                self.ctx.build_file.config.webroot,
            });
            try std.fmt.format(writer, self.innerFmt, self.args);
        }
    };
}

/// Caller owns returned memory.
pub fn replaceStrings(
    allocator: std.mem.Allocator,
    input: []const u8,
    replace_from: []const u8,
    replace_to: []const u8,
) ![]const u8 {
    const buffer_size = std.mem.replacementSize(
        u8,
        input,
        replace_from,
        replace_to,
    );
    var buffer = try allocator.alloc(u8, buffer_size);
    _ = std.mem.replace(
        u8,
        input,
        replace_from,
        replace_to,
        buffer,
    );

    return buffer;
}

pub const lexicographicalCompare = struct {
    pub fn inner(innerCtx: void, a: []const u8, b: []const u8) bool {
        _ = innerCtx;

        var i: usize = 0;
        if (a.len == 0 or b.len == 0) return false;
        while (a[i] == b[i]) : (i += 1) {
            if (i == a.len or i == b.len) return false;
        }

        return a[i] < b[i];
    }
}.inner;
