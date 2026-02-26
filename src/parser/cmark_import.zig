pub const c = @cImport({
    @cDefine("CMARK_NO_SHORT_NAMES", {});
    @cInclude("cmark-gfm.h");
    @cInclude("cmark-gfm-extension_api.h");
    @cInclude("cmark-gfm-core-extensions.h");
});
