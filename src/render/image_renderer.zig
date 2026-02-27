const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;
const render_utils = @import("render_utils.zig");
const Fonts = @import("../layout/text_measurer.zig").Fonts;

pub const ImageRenderer = struct {
    cache: std.StringHashMap(rl.Texture2D),
    allocator: Allocator,
    /// Directory of the markdown file, for resolving relative image paths
    base_dir: ?[]const u8,

    pub fn init(allocator: Allocator) ImageRenderer {
        return .{
            .cache = std.StringHashMap(rl.Texture2D).init(allocator),
            .allocator = allocator,
            .base_dir = null,
        };
    }

    pub fn setBaseDir(self: *ImageRenderer, dir: []const u8) void {
        if (self.base_dir) |old| self.allocator.free(old);
        self.base_dir = self.allocator.dupe(u8, dir) catch null;
    }

    /// Resolve a path relative to the markdown file's directory.
    fn resolvePath(self: *ImageRenderer, path: []const u8) ?[:0]const u8 {
        // Absolute paths pass through
        if (path.len > 0 and path[0] == '/') {
            return self.allocator.dupeZ(u8, path) catch null;
        }
        // Relative path: join with base_dir
        if (self.base_dir) |base| {
            const joined = std.fs.path.join(self.allocator, &.{ base, path }) catch return null;
            defer self.allocator.free(joined);
            return self.allocator.dupeZ(u8, joined) catch null;
        }
        // No base dir, try as-is
        return self.allocator.dupeZ(u8, path) catch null;
    }

    /// Load an image texture from a file path. Returns null if loading fails.
    pub fn loadImage(self: *ImageRenderer, path: []const u8) ?rl.Texture2D {
        const resolved = self.resolvePath(path) orelse return null;
        defer self.allocator.free(resolved);

        const texture = rl.loadTexture(resolved) catch return null;
        if (texture.id == 0) return null;

        // Enable bilinear filtering for smooth scaling
        rl.setTextureFilter(texture, .bilinear);
        return texture;
    }

    /// Get a cached texture or load it on cache miss.
    pub fn getOrLoad(self: *ImageRenderer, path: []const u8) ?rl.Texture2D {
        if (self.cache.get(path)) |texture| {
            return texture;
        }

        const texture = self.loadImage(path) orelse return null;

        // Store a durable copy of the path as the key
        const key = self.allocator.dupe(u8, path) catch return texture;
        self.cache.put(key, texture) catch {};
        return texture;
    }

    /// Draw a texture scaled to fit within a rectangle.
    pub fn drawImage(texture: rl.Texture2D, rect: @import("../layout/layout_types.zig").Rect, scroll_y: f32) void {
        const draw_y = rect.y - scroll_y;
        rl.drawTexturePro(
            texture,
            // Source: full texture
            .{ .x = 0, .y = 0, .width = @floatFromInt(texture.width), .height = @floatFromInt(texture.height) },
            // Dest: fit into layout rect
            .{ .x = rect.x, .y = draw_y, .width = rect.width, .height = rect.height },
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );
    }

    /// Draw a placeholder rectangle with alt text for missing images.
    pub fn drawPlaceholder(rect: @import("../layout/layout_types.zig").Rect, alt_text: ?[]const u8, fonts: *const Fonts, scroll_y: f32) void {
        const draw_y = rect.y - scroll_y;
        const placeholder_color = rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const border_color = rl.Color{ .r = 160, .g = 160, .b = 160, .a = 255 };

        // Gray background
        rl.drawRectangleRec(
            .{ .x = rect.x, .y = draw_y, .width = rect.width, .height = rect.height },
            placeholder_color,
        );
        // Border
        rl.drawRectangleLinesEx(
            .{ .x = rect.x, .y = draw_y, .width = rect.width, .height = rect.height },
            1.0,
            border_color,
        );

        // Alt text centered
        if (alt_text) |text| {
            if (text.len > 0) {
                const font_size: f32 = 14;
                const measured = fonts.measure(text, font_size, false, true, false);
                const text_x = rect.x + (rect.width - measured.x) / 2.0;
                const text_y = draw_y + (rect.height - measured.y) / 2.0;

                // Need null-terminated string for raylib
                var buf: [2048]u8 = undefined;
                const z_text = render_utils.sliceToZ(&buf, text);

                const font = fonts.selectFont(.{ .italic = true });
                rl.drawTextEx(font, z_text, .{ .x = text_x, .y = text_y }, font_size, 1, rl.Color{ .r = 100, .g = 100, .b = 100, .a = 255 });
            }
        }
    }

    /// Free all cached textures.
    pub fn unloadAll(self: *ImageRenderer) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            rl.unloadTexture(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.clearAndFree();
        if (self.base_dir) |dir| {
            self.allocator.free(dir);
            self.base_dir = null;
        }
    }
};
