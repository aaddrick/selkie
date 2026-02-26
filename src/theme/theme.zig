const rl = @import("raylib");

pub const Theme = struct {
    // Colors
    background: rl.Color,
    text: rl.Color,
    heading: [6]rl.Color,
    link: rl.Color,
    link_hover: rl.Color,
    code_text: rl.Color,
    code_background: rl.Color,
    blockquote_border: rl.Color,
    blockquote_text: rl.Color,
    table_header_bg: rl.Color,
    table_border: rl.Color,
    table_alt_row_bg: rl.Color,
    hr_color: rl.Color,
    scrollbar: rl.Color,
    scrollbar_track: rl.Color,

    // Syntax highlighting
    syntax_keyword: rl.Color,
    syntax_string: rl.Color,
    syntax_comment: rl.Color,
    syntax_number: rl.Color,
    syntax_type: rl.Color,
    syntax_function: rl.Color,
    syntax_operator: rl.Color,
    syntax_punctuation: rl.Color,
    line_number_color: rl.Color,

    // Sizing
    body_font_size: f32,
    heading_scale: [6]f32,
    mono_font_size: f32,
    line_height: f32,

    // Spacing
    paragraph_spacing: f32,
    heading_spacing_above: f32,
    heading_spacing_below: f32,
    list_indent: f32,
    blockquote_indent: f32,
    code_block_padding: f32,
    page_margin: f32,
    max_content_width: f32,
    table_cell_padding: f32 = 8,

    pub fn headingSize(self: Theme, level: u8) f32 {
        if (level == 0 or level > 6) return self.body_font_size;
        return self.body_font_size * self.heading_scale[level - 1];
    }

    pub fn headingColor(self: Theme, level: u8) rl.Color {
        if (level == 0 or level > 6) return self.text;
        return self.heading[level - 1];
    }
};
