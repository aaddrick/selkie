const rl = @import("raylib");
const Theme = @import("theme.zig").Theme;

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

pub const light = Theme{
    .background = rgb(255, 255, 255),
    .text = rgb(36, 41, 46),
    .heading = .{
        rgb(3, 102, 214), // h1
        rgb(36, 41, 46), // h2
        rgb(36, 41, 46), // h3
        rgb(36, 41, 46), // h4
        rgb(106, 115, 125), // h5
        rgb(106, 115, 125), // h6
    },
    .link = rgb(3, 102, 214),
    .link_hover = rgb(0, 64, 153),
    .code_text = rgb(36, 41, 46),
    .code_background = rgb(246, 248, 250),
    .blockquote_border = rgb(223, 226, 229),
    .blockquote_text = rgb(106, 115, 125),
    .table_header_bg = rgb(246, 248, 250),
    .table_border = rgb(223, 226, 229),
    .table_alt_row_bg = rgb(246, 248, 250),
    .hr_color = rgb(223, 226, 229),
    .scrollbar = rgb(180, 180, 180),
    .scrollbar_track = rgb(240, 240, 240),

    .body_font_size = 16,
    .heading_scale = .{ 2.0, 1.5, 1.25, 1.1, 0.9, 0.8 },
    .mono_font_size = 14,
    .line_height = 1.5,

    .paragraph_spacing = 16,
    .heading_spacing_above = 24,
    .heading_spacing_below = 8,
    .list_indent = 24,
    .blockquote_indent = 16,
    .code_block_padding = 12,
    .page_margin = 40,
    .max_content_width = 800,
};

pub const dark = Theme{
    .background = rgb(30, 30, 46),
    .text = rgb(205, 214, 244),
    .heading = .{
        rgb(137, 180, 250), // h1
        rgb(137, 220, 235), // h2
        rgb(166, 227, 161), // h3
        rgb(249, 226, 175), // h4
        rgb(250, 179, 135), // h5
        rgb(243, 139, 168), // h6
    },
    .link = rgb(137, 180, 250),
    .link_hover = rgb(180, 190, 254),
    .code_text = rgb(205, 214, 244),
    .code_background = rgb(49, 50, 68),
    .blockquote_border = rgb(88, 91, 112),
    .blockquote_text = rgb(166, 173, 200),
    .table_header_bg = rgb(49, 50, 68),
    .table_border = rgb(88, 91, 112),
    .table_alt_row_bg = rgb(30, 30, 46),
    .hr_color = rgb(88, 91, 112),
    .scrollbar = rgb(88, 91, 112),
    .scrollbar_track = rgb(30, 30, 46),

    .body_font_size = 16,
    .heading_scale = .{ 2.0, 1.5, 1.25, 1.1, 0.9, 0.8 },
    .mono_font_size = 14,
    .line_height = 1.5,

    .paragraph_spacing = 16,
    .heading_spacing_above = 24,
    .heading_spacing_below = 8,
    .list_indent = 24,
    .blockquote_indent = 16,
    .code_block_padding = 12,
    .page_margin = 40,
    .max_content_width = 800,
};
