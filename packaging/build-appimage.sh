#!/usr/bin/env bash
# Build an AppImage from a staged FHS tree.
# Usage: build-appimage.sh <staging_dir> <version> <arch>
#   staging_dir — directory containing usr/ tree (from zig build --prefix staging/usr)
#   version     — package version (e.g. 0.1.0)
#   arch        — architecture (amd64 or arm64)

set -euo pipefail

STAGING_DIR="${1:?Usage: build-appimage.sh <staging_dir> <version> <arch>}"
VERSION="${2:?Missing version}"
ARCH="${3:?Missing arch}"

COMPONENT_ID="io.github.aaddrick.selkie"
PKG_NAME="selkie"

# Map arch for appimagetool
case "$ARCH" in
    amd64)  APPIMAGE_ARCH="x86_64" ;;
    arm64)  APPIMAGE_ARCH="aarch64" ;;
    *)      echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

APPDIR="${COMPONENT_ID}.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr"

# Copy staged FHS tree
cp -a "$STAGING_DIR/usr/"* "$APPDIR/usr/"

# Create AppRun
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
exec "$APPDIR/usr/bin/selkie" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Copy desktop file to AppDir root (appimagetool requirement)
cp "$APPDIR/usr/share/applications/${COMPONENT_ID}.desktop" "$APPDIR/${COMPONENT_ID}.desktop"

# Copy 256px icon to AppDir root (appimagetool requirement)
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/selkie.png" "$APPDIR/selkie.png"

# Download appimagetool if not present (with retry)
APPIMAGETOOL="./appimagetool"
if [ ! -x "$APPIMAGETOOL" ]; then
    TOOL_ARCH="$APPIMAGE_ARCH"
    for i in 1 2 3; do
        curl -fsSL -o "$APPIMAGETOOL" \
            "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${TOOL_ARCH}.AppImage" && break
        echo "appimagetool download attempt $i failed, retrying in 10s..."
        sleep 10
    done
    chmod +x "$APPIMAGETOOL"
fi

# Pre-download runtime (with retry — GitHub CDN can return 502)
RUNTIME="./runtime-${APPIMAGE_ARCH}"
if [ ! -f "$RUNTIME" ]; then
    for i in 1 2 3; do
        curl -fsSL -o "$RUNTIME" \
            "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-${APPIMAGE_ARCH}" && break
        echo "Runtime download attempt $i failed, retrying in 10s..."
        sleep 10
    done
fi

OUTPUT="${PKG_NAME}-${VERSION}-${APPIMAGE_ARCH}.AppImage"

# Build AppImage
# In CI, embed zsync update info for delta updates
EXTRA_ARGS=(--runtime-file "$RUNTIME")
if [ "${CI:-}" = "true" ]; then
    EXTRA_ARGS+=(-u "gh-releases-zsync|aaddrick|selkie|latest|selkie-*-${APPIMAGE_ARCH}.AppImage.zsync")
fi

ARCH="$APPIMAGE_ARCH" "$APPIMAGETOOL" "${EXTRA_ARGS[@]}" "$APPDIR" "$OUTPUT"

rm -rf "$APPDIR"

echo "Built: $OUTPUT"
