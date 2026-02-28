const std = @import("std");

pub fn build(b: *std.Build) void {
    // Keep in sync with build.zig.zon, data/selkie.1, and metainfo.xml
    const version = "0.1.2";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options (version string, etc.) ---
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // --- raylib-zig dependency ---
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .linux_display_backend = .Both,
    });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    // --- cmark-gfm static C library ---
    const cmark_lib = b.addStaticLibrary(.{
        .name = "cmark-gfm",
        .target = target,
        .optimize = optimize,
    });
    cmark_lib.linkLibC();

    // Include paths: config headers first (override generated), then source, then extensions
    cmark_lib.addIncludePath(b.path("deps/cmark-gfm-config"));
    cmark_lib.addIncludePath(b.path("deps/cmark-gfm/src"));
    cmark_lib.addIncludePath(b.path("deps/cmark-gfm/extensions"));

    const cmark_flags = &.{"-std=c99"};

    cmark_lib.addCSourceFiles(.{
        .root = b.path("deps/cmark-gfm/src"),
        .files = &.{
            "arena.c",
            "blocks.c",
            "buffer.c",
            "cmark.c",
            "cmark_ctype.c",
            "commonmark.c",
            "footnotes.c",
            "houdini_href_e.c",
            "houdini_html_e.c",
            "houdini_html_u.c",
            "html.c",
            "inlines.c",
            "iterator.c",
            "linked_list.c",
            "map.c",
            "node.c",
            "plaintext.c",
            "plugin.c",
            "references.c",
            "registry.c",
            "render.c",
            "scanners.c",
            "syntax_extension.c",
            "utf8.c",
        },
        .flags = cmark_flags,
    });

    cmark_lib.addCSourceFiles(.{
        .root = b.path("deps/cmark-gfm/extensions"),
        .files = &.{
            "autolink.c",
            "core-extensions.c",
            "ext_scanners.c",
            "strikethrough.c",
            "table.c",
            "tagfilter.c",
            "tasklist.c",
        },
        .flags = cmark_flags,
    });

    // --- Selkie executable ---
    const exe = b.addExecutable(.{
        .name = "selkie",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Strip debug symbols in release builds
    exe.root_module.strip = if (optimize != .Debug) true else null;

    // Link dependencies
    exe.linkLibrary(raylib_artifact);
    exe.linkLibrary(cmark_lib);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addOptions("build_options", options);

    // cmark-gfm include paths for @cImport
    exe.addIncludePath(b.path("deps/cmark-gfm-config"));
    exe.addIncludePath(b.path("deps/cmark-gfm/src"));
    exe.addIncludePath(b.path("deps/cmark-gfm/extensions"));

    b.installArtifact(exe);

    // --- Install assets to share/selkie/ (FHS layout) ---
    b.installDirectory(.{
        .source_dir = b.path("assets/fonts"),
        .install_dir = .{ .custom = "share/selkie/fonts" },
        .install_subdir = "",
    });
    b.installDirectory(.{
        .source_dir = b.path("assets/themes"),
        .install_dir = .{ .custom = "share/selkie/themes" },
        .install_subdir = "",
    });

    // --- Install data files (desktop entry, metainfo, man page, icons) ---
    b.installFile("data/io.github.aaddrick.selkie.desktop", "share/applications/io.github.aaddrick.selkie.desktop");
    b.installFile("data/io.github.aaddrick.selkie.metainfo.xml", "share/metainfo/io.github.aaddrick.selkie.metainfo.xml");
    b.installFile("data/selkie.1", "share/man/man1/selkie.1");

    // Freedesktop hicolor icon theme — scalable SVG
    b.installFile("data/icons/selkie.svg", "share/icons/hicolor/scalable/apps/selkie.svg");

    // Freedesktop hicolor icon theme — PNG at each standard size
    const icon_sizes = [_][]const u8{ "16", "24", "32", "48", "64", "128", "256", "512" };
    inline for (icon_sizes) |size| {
        b.installFile(
            "data/icons/selkie-" ++ size ++ ".png",
            "share/icons/hicolor/" ++ size ++ "x" ++ size ++ "/apps/selkie.png",
        );
    }

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // --- Test step ---
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibrary(cmark_lib);
    unit_tests.linkLibrary(raylib_artifact);
    unit_tests.root_module.addImport("raylib", raylib);
    unit_tests.root_module.addOptions("build_options", options);
    unit_tests.addIncludePath(b.path("deps/cmark-gfm-config"));
    unit_tests.addIncludePath(b.path("deps/cmark-gfm/src"));
    unit_tests.addIncludePath(b.path("deps/cmark-gfm/extensions"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
