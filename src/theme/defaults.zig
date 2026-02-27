const rl = @import("raylib");
const Theme = @import("theme.zig").Theme;

fn rgb(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn rgba(r: u8, g: u8, b: u8, a: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
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

    // Menu bar
    .menu_bar_bg = rgb(246, 248, 250),
    .menu_text = rgb(36, 41, 46),
    .menu_hover_bg = rgb(230, 233, 237),
    .menu_active_bg = rgb(220, 224, 228),
    .menu_separator = rgb(208, 215, 222),

    // Syntax highlighting (GitHub-inspired light theme)
    .syntax_keyword = rgb(207, 34, 46),
    .syntax_string = rgb(10, 48, 105),
    .syntax_comment = rgb(106, 115, 125),
    .syntax_number = rgb(5, 80, 174),
    .syntax_type = rgb(102, 57, 186),
    .syntax_function = rgb(130, 80, 223),
    .syntax_operator = rgb(36, 41, 46),
    .syntax_punctuation = rgb(36, 41, 46),
    .line_number_color = rgb(175, 184, 193),

    // Search
    .search_highlight = rgba(255, 235, 59, 80), // Yellow, semi-transparent
    .search_current = rgba(255, 152, 0, 140), // Orange, more opaque
    .search_bar_bg = rgb(246, 248, 250),
    .search_bar_text = rgb(36, 41, 46),
    .search_bar_border = rgb(208, 215, 222),

    // Mermaid (light: blue-gray nodes, dark borders)
    .mermaid_node_fill = rgb(218, 232, 252),
    .mermaid_node_border = rgb(100, 130, 180),
    .mermaid_node_text = rgb(36, 41, 46),
    .mermaid_edge = rgb(100, 100, 100),
    .mermaid_edge_text = rgb(36, 41, 46),
    .mermaid_label_bg = rgb(232, 232, 232),
    .mermaid_subgraph_bg = rgb(240, 245, 255),

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

    // Menu bar (Catppuccin surface0/surface1)
    .menu_bar_bg = rgb(49, 50, 68),
    .menu_text = rgb(205, 214, 244),
    .menu_hover_bg = rgb(69, 71, 90),
    .menu_active_bg = rgb(88, 91, 112),
    .menu_separator = rgb(69, 71, 90),

    // Syntax highlighting (Catppuccin Mocha-inspired)
    .syntax_keyword = rgb(203, 166, 247),
    .syntax_string = rgb(166, 227, 161),
    .syntax_comment = rgb(108, 112, 134),
    .syntax_number = rgb(250, 179, 135),
    .syntax_type = rgb(249, 226, 175),
    .syntax_function = rgb(137, 180, 250),
    .syntax_operator = rgb(148, 226, 213),
    .syntax_punctuation = rgb(147, 153, 178),
    .line_number_color = rgb(108, 112, 134),

    // Search
    .search_highlight = rgba(250, 179, 135, 80), // Peach, semi-transparent
    .search_current = rgba(249, 226, 175, 140), // Yellow, more opaque
    .search_bar_bg = rgb(49, 50, 68),
    .search_bar_text = rgb(205, 214, 244),
    .search_bar_border = rgb(88, 91, 112),

    // Mermaid (Catppuccin-style teal/mauve fills)
    .mermaid_node_fill = rgb(69, 71, 90),
    .mermaid_node_border = rgb(148, 226, 213),
    .mermaid_node_text = rgb(205, 214, 244),
    .mermaid_edge = rgb(166, 173, 200),
    .mermaid_edge_text = rgb(205, 214, 244),
    .mermaid_label_bg = rgb(49, 50, 68),
    .mermaid_subgraph_bg = rgb(36, 36, 54),

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
