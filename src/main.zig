const std = @import("std");
const rl = @import("raylib");

const c = @cImport({
    @cInclude("cmark-gfm.h");
    @cInclude("cmark-gfm-core-extensions.h");
});

pub fn main() !void {
    // Quick smoke test: parse a tiny markdown string with cmark-gfm
    c.cmark_gfm_core_extensions_ensure_registered();
    const parser = c.cmark_parser_new(c.CMARK_OPT_DEFAULT);
    defer c.cmark_parser_free(parser);

    const md = "# Hello Selkie\n\nIt works!\n";
    c.cmark_parser_feed(parser, md, md.len);
    const doc = c.cmark_parser_finish(parser);
    defer c.cmark_node_free(doc);

    // Open a raylib window
    const screen_width = 800;
    const screen_height = 600;
    rl.initWindow(screen_width, screen_height, "Selkie — Markdown Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.ray_white);
        rl.drawText("Selkie — build system works!", 190, 280, 20, rl.Color.dark_gray);
    }
}
