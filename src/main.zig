const std = @import("std");
const koino = @import("koino");
const libpcre = @import("libpcre");

pub const OwnedStringList = std.ArrayList([]const u8);
pub const BuildFile = @import("build_file.zig").BuildFile;
const processors = @import("processors.zig");
const util = @import("util.zig");
const uuid = @import("uuid");

pub const std_options = std.Options{
    .log_level = .debug,
};

const logger = std.log.scoped(.obsidian2web);

const Page = @import("Page.zig");
const PageMap = std.StringHashMap(Page);

// article on path a/b/c/d/e.md is mapped as "e" in this title map.
const TitleMap = std.StringHashMap([]const u8);

const PathTree = @import("PathTree.zig");
pub const StringBuffer = std.ArrayList(u8);
pub const SliceList = std.ArrayList([]const u8);

const TreeGeneratorContext = struct {
    current_folder: ?PathTree.PageFolder = null,
    root_folder: ?PathTree.PageFolder = null,
    indentation_level: usize = 0,
};

fn printHashMap(map: anytype) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        logger.debug(
            "key={s} value={any}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
    }
}

fn writePageTree(
    writer: anytype,
    ctx: *const Context,
    tree_context: TreeGeneratorContext,
    /// Set this if generating a tree in a specific page.
    ///
    /// Set to null if on index page.
    generating_tree_for: ?*const Page,
) !void {
    const root_folder =
        tree_context.root_folder orelse
        PathTree.walkToDir(ctx.tree.root, ctx.build_file.vault_path);
    const current_folder =
        tree_context.current_folder orelse root_folder;

    // step 1: find all the folders at this level.

    var folders = SliceList.init(ctx.allocator);
    defer folders.deinit();

    var files = SliceList.init(ctx.allocator);
    defer files.deinit();

    {
        var folder_iterator = current_folder.iterator();

        while (folder_iterator.next()) |entry| {
            switch (entry.value_ptr.*) {
                .dir => try folders.append(entry.key_ptr.*),
                .file => try files.append(entry.key_ptr.*),
            }
        }

        std.sort.insertion([]const u8, folders.items, {}, util.lexicographicalCompare);
        std.sort.insertion([]const u8, files.items, {}, util.lexicographicalCompare);
    }

    // draw folders first (they recurse)
    // then draw files second

    for (folders.items) |folder_name| {
        try writer.print("<details>", .{});

        const child_folder = current_folder.getPtr(folder_name).?.dir;
        try writer.print(
            "<summary>{s}</summary>\n",
            .{util.unsafeHTML(folder_name)},
        );

        const child_context = TreeGeneratorContext{
            .indentation_level = tree_context.indentation_level + 1,
            .current_folder = child_folder,
        };

        try writePageTree(writer, ctx, child_context, generating_tree_for);
        try writer.print("</details>\n", .{});
    }

    const for_web_path = if (generating_tree_for) |current_page|
        try current_page.fetchWebPath(ctx.allocator)
    else
        null;
    defer if (for_web_path) |path| ctx.allocator.free(path);

    try writer.print("<ul>\n", .{});
    for (files.items) |file_name| {
        const file_path = current_folder.get(file_name).?.file;
        const page = ctx.pages.get(file_path).?;

        const page_web_path = try page.fetchWebPath(ctx.allocator);
        defer ctx.allocator.free(page_web_path);

        const current_attr = if (for_web_path != null and std.mem.eql(u8, for_web_path.?, page_web_path))
            "aria-current=\"page\" "
        else
            " ";

        try writer.print(
            "<li><a class=\"toc-link\" {s}href=\"{s}\">{s}</a></li>\n",
            .{
                current_attr,
                ctx.webPath("/{s}", .{page_web_path}),
                util.unsafeHTML(page.title),
            },
        );
    }
    try writer.print("</ul>\n", .{});
}

const testing = @import("testing.zig");
test "page tree sets aria-current" {
    const TEST_DATA = .{
        .{ "awoogapage", "", "<a class=\"toc-link\" aria-current=\"page\" href=\"/awoogapage.html\">awoogapage</a>" },
    };

    inline for (TEST_DATA) |test_entry| {
        const title = test_entry.@"0";
        const input = test_entry.@"1";
        const expected_output = test_entry.@"2";

        var test_ctx = testing.TestContext.init();
        defer test_ctx.deinit();

        try testing.runTestWithSingleEntry(&test_ctx, title, input, expected_output);
    }
}

const FOOTER =
    \\  <footer>
    \\    made with love using <a href="https://github.com/lun-4/obsidian2web">obsidian2web!</a>
    \\  </footer>
;

pub const ArenaHolder = struct {
    paths: std.heap.ArenaAllocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .paths = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.paths.deinit();
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    build_file: BuildFile,
    vault_dir: std.fs.Dir,
    arenas: ArenaHolder,
    pages: PageMap,
    titles: TitleMap,
    tree: PathTree,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        build_file: BuildFile,
        vault_dir: std.fs.Dir,
    ) Self {
        return Self{
            .allocator = allocator,
            .build_file = build_file,
            .vault_dir = vault_dir,
            .arenas = ArenaHolder.init(allocator),
            .pages = PageMap.init(allocator),
            .titles = TitleMap.init(allocator),
            .tree = PathTree.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arenas.deinit();
        {
            var it = self.pages.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit();
        }
        self.pages.deinit();
        self.titles.deinit();
        self.tree.deinit();
    }

    pub fn pathAllocator(self: *Self) std.mem.Allocator {
        return self.arenas.paths.allocator();
    }

    pub fn addPage(self: *Self, path: []const u8) !void {
        const owned_fspath = try self.pathAllocator().dupe(u8, path);

        // if not a page that should be rendered, add it to only titlemap
        const must_render =
            std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".canvas");

        if (!must_render) {
            const basename = std.fs.path.basename(owned_fspath);

            const titles_result = try self.titles.getOrPut(basename);
            if (!titles_result.found_existing) {
                titles_result.value_ptr.* = owned_fspath;
            }

            return;
        }

        const pages_result = try self.pages.getOrPut(owned_fspath);
        if (!pages_result.found_existing) {
            const page = try Page.fromPath(self, owned_fspath);
            pages_result.value_ptr.* = page;
            try self.titles.put(page.title, page.filesystem_path);
            try self.tree.addPath(page.filesystem_path);
        }
    }

    pub fn pageFromPath(self: Self, path: []const u8) ?Page {
        return self.pages.get(path);
    }

    pub fn pageFromTitle(self: Self, title: []const u8) ?Page {
        return self.pages.get(self.titles.get(title) orelse return null);
    }

    pub fn webPath(
        self: Self,
        comptime fmt: []const u8,
        args: anytype,
    ) util.WebPathPrinter(@TypeOf(args), fmt) {
        comptime std.debug.assert(fmt[0] == '/'); // must be path
        return util.WebPathPrinter(@TypeOf(args), fmt){
            .ctx = self,
            .args = args,
        };
    }
};

pub const ByteList = std.ArrayList(u8);

// insert into PageTree from the given include paths
pub fn iterateVaultPath(ctx: *Context) !void {
    for (ctx.build_file.includes.items) |relative_include_path| {
        const absolute_include_path = try std.fs.path.resolve(
            ctx.allocator,
            &[_][]const u8{ ctx.build_file.vault_path, relative_include_path },
        );
        defer ctx.allocator.free(absolute_include_path);

        logger.info("including given path: '{s}'", .{absolute_include_path});

        // attempt to openDir first, if it fails assume file
        var included_dir = std.fs.cwd().openDir(
            absolute_include_path,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.NotDir => {
                try ctx.addPage(absolute_include_path);
                continue;
            },

            else => return err,
        };
        defer included_dir.close();

        // Walker already recurses into all child paths

        var walker = try included_dir.walk(ctx.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const absolute_file_path = try std.fs.path.join(
                        ctx.allocator,
                        &[_][]const u8{ absolute_include_path, entry.path },
                    );
                    defer ctx.allocator.free(absolute_file_path);
                    try ctx.addPage(absolute_file_path);
                },

                else => {},
            }
        }
    }
}

pub fn main() anyerror!void {
    var allocator_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator_instance.deinit();

    const allocator = allocator_instance.allocator();

    var args_it = std.process.args();
    defer args_it.deinit();

    _ = args_it.skip();
    const build_file_path = args_it.next() orelse {
        logger.err("pass path to build file as 1st argument", .{});
        return error.InvalidArguments;
    };

    var build_file_data_buffer: [8192]u8 = undefined;
    const build_file_data = blk: {
        const build_file_fd = try std.fs.cwd().openFile(
            build_file_path,
            .{ .mode = .read_only },
        );
        defer build_file_fd.close();

        const build_file_data_count = try build_file_fd.read(
            &build_file_data_buffer,
        );
        break :blk build_file_data_buffer[0..build_file_data_count];
    };

    var build_file = try BuildFile.parse(allocator, build_file_data);
    defer build_file.deinit();

    var vault_dir = try std.fs.cwd().openDir(build_file.vault_path, .{ .iterate = true });
    defer vault_dir.close();

    var ctx = Context.init(allocator, build_file, vault_dir);
    defer ctx.deinit();

    // main pipeline starts here
    {
        try iterateVaultPath(&ctx);
        try std.fs.cwd().makePath("public/");
        try createStaticResources(ctx);

        // for each page
        //  - pass 1: run pre processors
        //  - pass 2: turn page markdown into html (koino)
        //  - pass 3: run post processors

        var pre_processors = try initProcessors(PreProcessors);
        defer deinitProcessors(pre_processors);

        var post_processors = try initProcessors(PostProcessors);
        defer deinitProcessors(post_processors);

        var pages_it = ctx.pages.iterator();
        while (pages_it.next()) |entry| {
            try runProcessors(&ctx, &pre_processors, entry.value_ptr, .{ .pre = true });
            try mainPass(&ctx, entry.value_ptr);
            try runProcessors(&ctx, &post_processors, entry.value_ptr, .{});
        }
    }

    try std.fs.cwd().makePath("public/images");
    var titles_it = ctx.titles.iterator();
    while (titles_it.next()) |entry| {
        const fspath = entry.value_ptr.*;
        const maybe_page = ctx.pages.get(fspath);
        if (maybe_page != null) continue;
        var output_path_buffer: [std.posix.PATH_MAX]u8 = undefined;
        const output_path = try std.fmt.bufPrint(
            &output_path_buffer,
            "public/images/{s}",
            .{std.fs.path.basename(fspath)},
        );
        try std.fs.cwd().copyFile(fspath, std.fs.cwd(), output_path, .{});
    }

    // end processors are for features that only work once *all* pages
    // were successfully processed (like tag pages).
    {
        var end_processors = try initProcessors(EndProcessors);
        defer deinitProcessors(end_processors);

        var pages_it = ctx.pages.iterator();
        logger.info("running end processors", .{});
        while (pages_it.next()) |entry| {
            try runProcessors(&ctx, &end_processors, entry.value_ptr, .{ .end = true });
        }
    }

    // generate index page
    try generateIndexPage(ctx);
    try generateTagPages(ctx);
    if (ctx.build_file.config.rss) |rss_root|
        try generateRSSFeed(ctx, rss_root);
}

pub const PostProcessors = struct {
    checkmark: processors.CheckmarkProcessor,
    cross_page_link: processors.CrossPageLinkProcessor,
};

pub const EndProcessors = struct {
    recent_pages: processors.RecentPagesProcessor,
};

pub const PreProcessors = struct {
    code: processors.CodeblockProcessor,
    tag: processors.TagProcessor,
    page_toc: processors.TableOfContentsProcessor,
    set_first_image: processors.SetFirstImageProcessor,
    twitter: processors.StaticTwitterEmbed,
    at_dates: processors.AtDatesProcessor,
};

pub fn initProcessors(comptime ProcessorHolderT: type) !ProcessorHolderT {
    var proc: ProcessorHolderT = undefined;
    inline for (@typeInfo(ProcessorHolderT).Struct.fields) |field| {
        @field(proc, field.name) = try field.type.init();
    }
    return proc;
}

pub fn deinitProcessors(procs: anytype) void {
    inline for (@typeInfo(@TypeOf(procs)).Struct.fields) |field| {
        field.type.deinit(@field(procs, field.name));
    }
}

// Contains data that will be sent to the processor
pub fn Holder(comptime ProcessorT: type, comptime WriterT: type) type {
    return struct {
        ctx: *Context,
        processor: ProcessorT,
        page: *Page,
        last_capture: *?libpcre.Capture,
        out: WriterT,
    };
}

const RunProcessorOptions = struct {
    pre: bool = false,
    end: bool = false,
};

pub fn runProcessors(
    ctx: *Context,
    processor_list: anytype,
    page: *Page,
    options: RunProcessorOptions,
) !void {
    logger.info("running processors processing {} {}", .{ page, options });

    const temp_output_path: []const u8 = if (options.pre) blk: {
        std.debug.assert(page.state == .unbuilt);
        var markdown_output_path = "/tmp/sex.md"; // TODO fetchTemporaryMarkdownPath();

        try std.fs.Dir.copyFile(
            std.fs.cwd(),
            page.filesystem_path,
            std.fs.cwd(),
            markdown_output_path,
            .{},
        );
        break :blk markdown_output_path[0..];
    } else blk: {
        if (options.end) {
            if (page.state != .post) {
                logger.err("expected page to be on post state, got {}", .{page.state});
                return error.UnexpectedPageState;
            }
        } else {
            if (page.state != .main) {
                logger.err("expected page to be on main state, got {}", .{page.state});
                return error.UnexpectedPageState;
            }
        }
        break :blk try page.fetchHtmlPath(ctx.allocator);
    };

    defer page.state = if (options.pre)
        .{ .pre = temp_output_path }
    else
        .{ .post = {} };

    defer if (!options.pre) ctx.allocator.free(temp_output_path);

    inline for (
        @typeInfo(@typeInfo(@TypeOf(processor_list)).Pointer.child).Struct.fields,
    ) |field| {
        const processor = @field(processor_list, field.name);
        logger.debug("running {s}", .{@typeName(field.type)});

        const output_file_contents = blk: {
            var output_fd = try std.fs.cwd().openFile(
                temp_output_path,
                .{ .mode = .read_only },
            );
            defer output_fd.close();

            break :blk try output_fd.reader().readAllAlloc(
                ctx.allocator,
                std.math.maxInt(usize),
            );
        };
        defer ctx.allocator.free(output_file_contents);

        var result = ByteList.init(ctx.allocator);
        defer result.deinit();

        const HolderT = Holder(@TypeOf(processor), ByteList.Writer);

        var last_capture: ?libpcre.Capture = null;
        var context_holder = HolderT{
            .ctx = ctx,
            .processor = processor,
            .page = page,
            .last_capture = &last_capture,
            .out = result.writer(),
        };

        try util.captureWithCallback(
            processor.regex,
            output_file_contents,
            .{},
            ctx.allocator,
            HolderT,
            &context_holder,
            struct {
                fn inner(
                    holder: *HolderT,
                    full_string: []const u8,
                    capture: []?libpcre.Capture,
                ) anyerror!void {
                    const first_group = capture[0].?;
                    _ = if (holder.last_capture.* == null)
                        try holder.out.write(
                            full_string[0..first_group.start],
                        )
                    else
                        try holder.out.write(
                            full_string[holder.last_capture.*.?.end..first_group.start],
                        );

                    try holder.processor.handle(
                        holder,
                        full_string,
                        capture,
                    );
                    holder.last_capture.* = first_group;
                }
            }.inner,
        );

        _ = if (last_capture == null)
            try result.writer().write(output_file_contents)
        else
            try result.writer().write(
                output_file_contents[last_capture.?.end..output_file_contents.len],
            );

        {
            var output_fd = try std.fs.cwd().openFile(
                temp_output_path,
                .{ .mode = .write_only },
            );
            defer output_fd.close();
            _ = try output_fd.write(result.items);
        }
    }
}

pub fn mainPass(ctx: *Context, page: *Page) !void {
    logger.info("processing '{s}'", .{page.filesystem_path});

    // TODO find a way to feed chunks of file to koino
    //
    // i did that before and failed miserably...
    const input_page_contents = blk: {
        var page_fd = try std.fs.cwd().openFile(
            page.state.pre,
            .{ .mode = .read_only },
        );
        defer page_fd.close();

        break :blk try page_fd.reader().readAllAlloc(
            ctx.allocator,
            std.math.maxInt(usize),
        );
    };
    defer ctx.allocator.free(input_page_contents);

    const options = .{
        .extensions = .{
            .autolink = true,
            .strikethrough = true,
            .table = true,
        },
        .render = .{ .hard_breaks = true, .unsafe = true },
    };

    var output_fd = blk: {
        const html_path = try page.fetchHtmlPath(ctx.allocator);
        defer ctx.allocator.free(html_path);
        logger.info("writing to '{s}'", .{html_path});

        const leading_path_to_file = std.fs.path.dirname(html_path).?;
        try std.fs.cwd().makePath(leading_path_to_file);

        break :blk try std.fs.cwd().createFile(
            html_path,
            .{ .read = false, .truncate = true },
        );
    };
    defer output_fd.close();

    defer page.state = .{ .main = {} };

    var output = output_fd.writer();

    // write time
    {
        try writeHead(output, ctx.build_file, page.title, page.*);

        try writePageTree(output, ctx, .{}, page);
        try output.print(
            \\  <hr>
        , .{});
        if (page.titles) |titles| for (titles.items) |title| {
            try output.print(
                \\  <a class="heading" href="#{s}">{s}</a></p>
            , .{
                util.WebTitlePrinter{ .title = title },
                title,
            });
        };

        try output.print(
            \\  <hr>
        , .{});
        if (page.tags) |tags| for (tags.items) |tag| {
            try output.print(
                \\  <a class="tag" href="{}">#{s}</a></p>
            , .{
                ctx.webPath("/_/tags/{s}.html", .{tag}),
                tag,
            });
        };

        try output.print(
            \\  </nav>
            \\  <main class="text">
        , .{});
        switch (page.page_type) {
            .md => {
                try output.print(
                    \\    <h2>{s}</h2><p>
                , .{util.unsafeHTML(page.title)});

                var parser = try koino.parser.Parser.init(ctx.allocator, options);
                defer parser.deinit();

                try parser.feed(input_page_contents);

                var doc = try parser.finish();
                defer doc.deinit();

                try koino.html.print(output, ctx.allocator, options, doc);
            },
            .canvas => {
                // base canvas html goes here

                const CanvasNode = struct {
                    id: []const u8,
                    x: isize,
                    y: isize,
                    width: usize,
                    height: usize,
                    type: []const u8,
                    text: []const u8,
                    color: []const u8 = "0",
                };

                const CanvasEdge = struct {
                    id: []const u8,
                    fromNode: []const u8,
                    fromSide: []const u8 = "bottom", // NOTE: spec does not define the default.
                    fromEnd: ?[]const u8 = "none",
                    toNode: []const u8,
                    toSide: []const u8 = "top", // NOTE: spec does not define the default.
                    toEnd: ?[]const u8 = "arrow",
                    label: ?[]const u8 = null,
                };

                const CanvasData = struct {
                    nodes: []CanvasNode,
                    edges: []CanvasEdge,
                };

                var parsed = try std.json.parseFromSlice(CanvasData, ctx.allocator, input_page_contents, .{ .allocate = .alloc_always });
                defer parsed.deinit();

                const canvas = parsed.value;

                try output.print(
                    \\  <div id="container">
                    \\    <div id="canvas-container">
                    \\      <svg id="canvas-edges">
                    \\        <defs>
                    \\          <marker id="arrowhead" markerWidth="10" markerHeight="8"
                    \\          refX="5" refY="4" orient="auto">
                    \\            <polygon points="0 0, 10 4, 0 8"/>
                    \\          </marker>
                    \\        </defs>
                    \\        <g id="edge-paths">
                    \\        </g>
                    \\      </svg>
                    \\      <div id="canvas-nodes">
                , .{});

                for (canvas.nodes) |node| {
                    // print an html node for each

                    var node_parser = try koino.parser.Parser.init(ctx.allocator, options);
                    defer node_parser.deinit();

                    try node_parser.feed(node.text);

                    var node_doc = try node_parser.finish();
                    defer node_doc.deinit();

                    var color_class_buf: [32]u8 = undefined;
                    var color_style_buf: [128]u8 = undefined;
                    const color_class = if (std.mem.startsWith(u8, node.color, "#"))
                        ""
                    else
                        std.fmt.bufPrint(&color_class_buf, "o2w-canvas-color-{s}", .{node.color}) catch unreachable;

                    const color_style = if (std.mem.startsWith(u8, node.color, "#"))
                        // TODO compute darker color
                        std.fmt.bufPrint(&color_style_buf, "--color-ui-1: {s}; --color-bg-1: color-mix(in srgb, {s} 20%, black)", .{ node.color, node.color }) catch unreachable
                    else
                        "";
                    try output.print(
                        \\ <node id="{s}" class="node node-text {s}" data-node-type="{s}" style="left: {d}px; top: {d}px; width: {d}px; height: {d}px; {s}">
                        \\   <div class="node-name"></div>
                        \\   <div class="node-text-content">
                    , .{
                        node.id,
                        color_class,
                        node.type,
                        node.x,
                        node.y,
                        node.width,
                        node.height,
                        color_style,
                    });
                    //try output.print("{s}\n", .{node.text});
                    // don't parse markdown for now
                    try koino.html.print(output, ctx.allocator, options, node_doc);
                    try output.print(
                        \\   </div>
                        \\ </node>
                    , .{});
                }

                try output.print(
                    \\      </div>
                    \\      <div id="output" class="theme-dark hidden">
                    \\        <div class="code-header">
                    \\          <span class="language">JSON&nbsp;Canvas</span>
                    \\          <span class="close-output">×</span>
                    \\        </div>
                    \\        <div id="output-code">
                    \\          <pre><code class="language-json" id="positionsOutput"></code></pre>
                    \\        </div>
                    \\         <div class="code-footer">
                    \\          <button class="button-copy">Copy code</button>
                    \\          <button class="button-download">Download file</button>
                    \\        </div>
                    \\      </div>
                    \\      <div id="controls">
                    \\        <div id="zoom-controls">
                    \\          <button id="toggle-output">Toggle output</button>
                    \\          <button id="zoom-out">Zoom out</button>
                    \\          <button id="zoom-in">Zoom in</button>
                    \\          <button id="zoom-reset">Reset</button>
                    \\        </div>
                    \\      </div>
                    \\    </div>
                    \\  </div>
                    \\
                , .{});

                try output.print(
                    \\ <script>
                    \\ let edges = [
                , .{});
                for (canvas.edges) |edge| {
                    var label_buf: [256]u8 = undefined;
                    try output.print(
                        \\    {{
                        \\      id: "{s}",
                        \\      fromNode: "{s}",
                        \\      fromSide: "{s}",
                        \\      fromEnd: "{s}",
                        \\      toNode: "{s}",
                        \\      toSide: "{s}",
                        \\      toEnd: "{s}",
                        \\      label: {s},
                        \\    }},
                    , .{
                        edge.id,
                        edge.fromNode,
                        edge.fromSide,
                        if (edge.fromEnd) |end| end else "none",
                        edge.toNode,
                        edge.toSide,
                        if (edge.toEnd) |end| end else "none",
                        if (edge.label) |label| std.fmt.bufPrint(&label_buf, "\"{s}\"", .{label}) catch unreachable else "null",
                    });
                }
                try output.print(
                    \\ ];
                    \\ </script>
                , .{});

                // inject canvas.js at the end (due to edges declaration)
                try output.print(
                // TODO do we need prism?
                    \\    <script src="{s}/prism.js"></script>
                    \\    <script src="{s}/canvas.js"></script>
                , .{
                    ctx.build_file.config.webroot,
                    ctx.build_file.config.webroot,
                });
            },
        }

        try output.print(
            \\  </p></main>
            \\ {s}
            \\ </body>
            \\ </html>
        , .{if (ctx.build_file.config.project_footer) FOOTER else ""});
    }
}

fn generateIndexPage(ctx: Context) !void {
    // if an index file was provided in the config, copypaste the resulting
    // HTML as that'll work
    if (ctx.build_file.config.index) |relative_index_path| {
        const page_path = try std.fs.path.resolve(
            ctx.allocator,
            &[_][]const u8{ ctx.build_file.vault_path, relative_index_path },
        );
        defer ctx.allocator.free(page_path);
        const page =
            ctx.pages.get(page_path) orelse return error.IndexPageNotFound;

        const html_path = try page.fetchHtmlPath(ctx.allocator);
        defer ctx.allocator.free(html_path);

        try std.fs.Dir.copyFile(
            std.fs.cwd(),
            html_path,
            std.fs.cwd(),
            "public/index.html",
            .{},
        );
    } else {
        // if not, generate our own empty file
        // that contains just the table of contents

        const index_out_fd = try std.fs.cwd().createFile(
            "public/index.html",
            .{ .truncate = true },
        );
        defer index_out_fd.close();

        const writer = index_out_fd.writer();

        try writeHead(writer, ctx.build_file, "Index Page", null);
        try writePageTree(writer, &ctx, .{}, null);
        try writeEmptyPage(writer, ctx.build_file);
    }
}

const PageList = std.ArrayList(*const Page);

const TagMap = std.StringHashMap(PageList);
fn generateTagPages(ctx: Context) !void {
    var tag_map = TagMap.init(ctx.allocator);

    defer {
        var tags_it = tag_map.iterator();
        while (tags_it.next()) |entry| entry.value_ptr.deinit();
        tag_map.deinit();
    }

    var it = ctx.pages.iterator();
    while (it.next()) |entry| {
        const page = entry.value_ptr;
        logger.debug("processing tags in {}", .{page});

        if (page.tags) |tags| for (tags.items) |tag| {
            var maybe_pagelist = try tag_map.getOrPut(tag);

            if (!maybe_pagelist.found_existing) {
                maybe_pagelist.value_ptr.* = PageList.init(ctx.allocator);
            }
            try maybe_pagelist.value_ptr.append(entry.value_ptr);
        };
    }

    try std.fs.cwd().makePath("public/_/tags");

    var tags_it = tag_map.iterator();
    while (tags_it.next()) |entry| {
        const tag_name = entry.key_ptr.*;
        logger.info("generating tag page: {s}", .{tag_name});
        var buf: [512]u8 = undefined;
        const output_path = try std.fmt.bufPrint(
            &buf,
            "public/_/tags/{s}.html",
            .{tag_name},
        );

        var output_file = try std.fs.cwd().createFile(
            output_path,
            .{ .read = false, .truncate = true },
        );
        defer output_file.close();

        var writer = output_file.writer();

        try writeHead(writer, ctx.build_file, tag_name, null);

        try writer.print(
            \\ <h3 style="text-align:center"><a href="{s}">Go to tag index</a></h3>
        , .{
            ctx.webPath("/_/tag_index.html", .{}),
        });

        _ = try writer.write(
            \\  </nav>
            \\  <main class="text">
        );

        std.sort.insertion(*const Page, entry.value_ptr.items, {}, struct {
            fn inner(context: void, a: *const Page, b: *const Page) bool {
                _ = context;
                return a.attributes.ctime < b.attributes.ctime;
            }
        }.inner);

        try writer.print("<h1>{s}</h1><p>", .{util.unsafeHTML(tag_name)});
        try writer.print("({d} pages)", .{entry.value_ptr.items.len});
        try writer.print("<div class=\"tag-page\">", .{});

        for (entry.value_ptr.items) |page| {
            var preview_buffer: [256]u8 = undefined;
            const page_preview_text = try page.fetchPreview(&preview_buffer);
            const page_web_path = try page.fetchWebPath(ctx.allocator);
            defer ctx.allocator.free(page_web_path);
            try writer.print(
                \\ <div class="page-preview">
                \\ 	<a href="{s}">
                \\ 		<div class="page-preview-title"><h2>{s}</h2></div>
                \\ 		<div class="page-preview-text">{s}&hellip;</div>
                \\ 	</a>
                \\ </div><p>
            ,
                .{
                    ctx.webPath("/{s}", .{page_web_path}),
                    util.unsafeHTML(page.title),
                    util.unsafeHTML(page_preview_text),
                },
            );
        }

        try writer.print("</div>", .{});

        _ = try writer.write(
            \\  </main>
        );

        if (ctx.build_file.config.project_footer) {
            _ = try writer.write(FOOTER);
        }

        _ = try writer.write(
            \\  </body>
            \\</html>
        );
    }

    try generateTagIndex(ctx, tag_map);
}

fn generateTagIndex(ctx: Context, tag_map: TagMap) !void {
    logger.info("generating tag index", .{});
    var output_file = try std.fs.cwd().createFile(
        "public/_/tag_index.html",
        .{ .read = false, .truncate = true },
    );
    defer output_file.close();

    var writer = output_file.writer();

    try writeHead(writer, ctx.build_file, "Tag Index", null);
    _ = try writer.write(
        \\  </nav>
        \\  <main class="text">
    );

    var tags = try SliceList.initCapacity(ctx.allocator, tag_map.unmanaged.size);
    defer tags.deinit();

    var tags_it = tag_map.iterator();
    while (tags_it.next()) |entry| {
        const tag_name = entry.key_ptr.*;
        try tags.append(tag_name);
    }

    std.sort.insertion([]const u8, tags.items, tag_map, struct {
        fn inner(context: TagMap, a: []const u8, b: []const u8) bool {
            return context.get(a).?.items.len > context.get(b).?.items.len;
        }
    }.inner);

    try writer.print("<div class=\"tag-page\">", .{});
    for (tags.items) |tag_name| {
        try writer.print("<div class=\"tag-box\">", .{});

        const pages = tag_map.get(tag_name).?;
        try writer.print(
            \\ <a href="{s}">
            \\ <h4>{s}</h4>
            \\ </a>
            \\ ({d} pages)
        , .{
            ctx.webPath("/_/tags/{s}.html", .{tag_name}),
            util.unsafeHTML(tag_name),
            pages.items.len,
        });

        try writer.print("</div>", .{});
    }
    try writer.print("</div>", .{});
    _ = try writer.write(
        \\  </main>
    );

    if (ctx.build_file.config.project_footer) {
        _ = try writer.write(FOOTER);
    }

    _ = try writer.write(
        \\  </body>
        \\</html>
    );
}

fn writeHead(writer: anytype, build_file: BuildFile, title: []const u8, maybe_page: ?Page) !void {
    try writer.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>{s}</title>
        \\    <meta property="og:title" content="{s}" />
        \\    <meta property="og:type" content="article" />
    , .{
        util.unsafeHTML(title),
        util.unsafeHTML(title),
    });

    if (maybe_page) |page| {
        if (page.maybe_first_image) |image_url| {
            try writer.print(
                \\ <meta property="og:image" content="{s}" />
            , .{image_url});
        }

        var buffer: [256]u8 = undefined;
        try writer.print(
            \\ <meta property="og:description" content="{s}" />
        , .{util.unsafeHTML(try page.fetchPreview(&buffer))});
    }

    try writer.print(
        \\    <script src="{s}/main.js"></script>
        \\    <script src="{s}/at-date.js"></script>
        \\    <link rel="stylesheet" href="{s}/styles.css">
        \\    <link rel="stylesheet" href="{s}/pygments.css">
        \\  </head>
        \\  <body>
        \\  <nav class="toc">
    , .{
        build_file.config.webroot,
        build_file.config.webroot,
        build_file.config.webroot,
        build_file.config.webroot,
    });
}

// TODO make this usable on the main pipeline too?
fn writeEmptyPage(writer: anytype, build_file: BuildFile) !void {
    _ = try writer.write(
        \\  </nav>
        \\  <main class="text">
        \\  </main>
    );

    if (build_file.config.project_footer) {
        _ = try writer.write(FOOTER);
    }

    _ = try writer.write(
        \\  </body>
        \\</html>
    );
}

fn createStaticResources(ctx: Context) !void {
    const RESOURCES = .{
        .{ "resources/styles.css", "styles.css" },
        .{ "resources/main.js", "main.js" },
        .{ "resources/at-date.js", "at-date.js" },
        .{ "resources/canvas.js", "canvas.js" },
        .{ "resources/prism.js", "prism.js" },
        .{ "resources/pygments.css", "pygments.css" },
    };

    inline for (RESOURCES) |resource| {
        const resource_text = @embedFile(resource.@"0");
        const resource_filename = resource.@"1";
        const output_fspath = "public/" ++ resource_filename;

        if (std.mem.eql(u8, resource_filename, "styles.css") and
            ctx.build_file.config.custom_css != null)
        {
            try std.fs.Dir.copyFile(
                std.fs.cwd(),
                ctx.build_file.config.custom_css.?,
                std.fs.cwd(),
                output_fspath,
                .{},
            );
        } else {
            var output_fd = try std.fs.cwd().createFile(
                output_fspath,
                .{ .truncate = true },
            );
            defer output_fd.close();
            // write it all lmao
            const written_bytes = try output_fd.write(resource_text);
            std.debug.assert(written_bytes == resource_text.len);
        }
    }
}

fn toRFC822(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    var argv = SliceList.init(allocator);
    defer argv.deinit();

    const unix_date = try std.fmt.allocPrint(allocator, "@{d}", .{timestamp});
    defer allocator.free(unix_date);

    try argv.appendSlice(&[_][]const u8{
        "date",
        "-d",
        unix_date,
        "+\"%a, %d %b %Y %H:%M:%S %z\"",
    });

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("TZ", "UTC");

    const result = try std.ChildProcess.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 256,
        .expand_arg0 = .expand,
        .env_map = &env_map,
    });
    logger.debug(
        "date sent stdout {d} bytes, stderr {d} bytes",
        .{ result.stdout.len, result.stderr.len },
    );

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            logger.err("date returned {} => {s}", .{ code, result.stderr });
            return error.DateFailed;
        },
        else => |code| {
            logger.err("date returned {} => {s}", .{ code, result.stderr });
            return error.DateFailed;
        },
    }

    defer allocator.free(result.stderr);
    return result.stdout;
}

fn rssGUID(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    var hasher = std.hash.XxHash64.init(69);
    hasher.update(title);
    const hash = hasher.final();
    var rng = std.rand.DefaultPrng.init(hash);
    var hash_as_uuid = uuid.UUID{ .bytes = undefined };
    rng.random().bytes(&hash_as_uuid.bytes);
    return try std.fmt.allocPrint(
        allocator,
        "{}",
        .{hash_as_uuid},
    );
}

fn generateRSSFeed(ctx: Context, rss_root: []const u8) !void {
    var rss_file = try std.fs.Dir.createFile(
        std.fs.cwd(),
        "public/feed.xml",
        .{ .truncate = true },
    );
    defer rss_file.close();

    var writer = rss_file.writer();

    const rss_date = try toRFC822(ctx.allocator, std.time.timestamp());
    defer ctx.allocator.free(rss_date);

    try writer.print(
        \\<?xml version="1.0" encoding="UTF-8" ?>
        \\<rss version="2.0">
        \\<channel>
        \\ <title>{s}</title>
        \\ <description>{s}</description>
        \\ <link>{s}</link>
        \\ <lastBuildDate>{s}</lastBuildDate>
        // \\ <pubDate>Sun, 6 Sep 2009 16:20:00 +0000</pubDate>
        \\ <ttl>1800</ttl>
    , .{
        ctx.build_file.config.rss_title orelse return error.MissingRSSTitle,
        ctx.build_file.config.rss_description orelse return error.MissingRSSDescription,
        rss_root,
        rss_date[1 .. rss_date.len - 2],
    });

    var pages = PageList.init(ctx.allocator);
    defer pages.deinit();
    var it = ctx.pages.iterator();
    while (it.next()) |entry| {
        const page = entry.value_ptr;
        try pages.append(page);
    }

    std.sort.insertion(*const Page, pages.items, {}, struct {
        fn inner(context: void, a: *const Page, b: *const Page) bool {
            _ = context;
            return a.attributes.ctime > b.attributes.ctime;
        }
    }.inner);

    for (pages.items, 0..) |page, idx| {
        if (idx > 20) break;

        var preview_buffer: [256]u8 = undefined;
        const page_preview_text = try page.fetchPreview(&preview_buffer);
        const page_web_path = try page.fetchWebPath(ctx.allocator);
        defer ctx.allocator.free(page_web_path);

        const page_pub_date = try toRFC822(ctx.allocator, page.attributes.ctime);
        defer ctx.allocator.free(page_pub_date);
        const guid = try rssGUID(ctx.allocator, page.title);
        defer ctx.allocator.free(guid);
        try writer.print(
            \\ <item>
            \\  <title>{s}</title>
            \\  <description>{s}</description>
            \\  <link>{s}{s}</link>
            \\  <guid isPermaLink="false">{s}</guid>
            \\  <pubDate>{s}</pubDate>
            \\ </item>
        ,
            .{
                util.unsafeHTML(page.title),
                util.unsafeHTML(page_preview_text),
                rss_root,
                ctx.webPath("/{s}", .{page_web_path}),
                guid,
                page_pub_date[1 .. page_pub_date.len - 2],
            },
        );
    }
    try writer.print(
        \\</channel>
        \\</rss>
    , .{});
}

test "basic test" {
    _ = std.testing.refAllDecls(@This());
}
