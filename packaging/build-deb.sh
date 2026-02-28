#!/usr/bin/env bash
# Build a .deb package from a staged FHS tree.
# Usage: build-deb.sh <staging_dir> <version> <arch>
#   staging_dir — directory containing usr/ tree (from zig build --prefix staging/usr)
#   version     — package version (e.g. 0.1.0)
#   arch        — Debian architecture (amd64 or arm64)

set -euo pipefail

STAGING_DIR="${1:?Usage: build-deb.sh <staging_dir> <version> <arch>}"
VERSION="${2:?Missing version}"
ARCH="${3:?Missing arch}"

COMPONENT_ID="io.github.aaddrick.selkie"
PKG_NAME="selkie"
PKG_DIR="${PKG_NAME}_${VERSION}_${ARCH}"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"

# Copy staged FHS tree
cp -a "$STAGING_DIR/usr" "$PKG_DIR/usr"

# Calculate installed size in KB
INSTALLED_SIZE=$(du -sk "$PKG_DIR/usr" | cut -f1)

# Generate control file
cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: text
Priority: optional
Architecture: ${ARCH}
Installed-Size: ${INSTALLED_SIZE}
Depends: libc6, libx11-6, libglx0, libxcursor1, libxext6, libxfixes3, libxi6, libxinerama1, libxrandr2, libxrender1, libegl1, libwayland-client0, libxkbcommon0
Recommends: zenity
Maintainer: aaddrick <aaddrick@users.noreply.github.com>
Homepage: https://github.com/aaddrick/selkie
Description: Markdown viewer with GFM support and Mermaid chart rendering
 Selkie is a Zig-based GUI markdown viewer with GitHub Flavored Markdown
 support, native Mermaid chart rendering, and theming.
EOF

# Generate postinst
cat > "$PKG_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/postinst"

# Generate postrm
cat > "$PKG_DIR/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database /usr/share/mime || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "$PKG_DIR"

echo "Built: ${PKG_DIR}.deb"
