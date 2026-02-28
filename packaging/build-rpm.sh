#!/usr/bin/env bash
# Build an .rpm package from a staged FHS tree.
# Usage: build-rpm.sh <staging_dir> <version> <arch>
#   staging_dir — directory containing usr/ tree (from zig build --prefix staging/usr)
#   version     — package version (e.g. 0.1.0)
#   arch        — Debian-style architecture (amd64 or arm64), mapped to RPM arch

set -euo pipefail

STAGING_DIR="${1:?Usage: build-rpm.sh <staging_dir> <version> <arch>}"
VERSION="${2:?Missing version}"
ARCH="${3:?Missing arch}"

# Map Debian arch to RPM arch
case "$ARCH" in
    amd64)  RPM_ARCH="x86_64" ;;
    arm64)  RPM_ARCH="aarch64" ;;
    *)      echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

PKG_NAME="selkie"
STAGING_DIR="$(cd "$STAGING_DIR" && pwd)"

# Set up rpmbuild tree in a temp directory
RPMBUILD_DIR="$(mktemp -d)"
mkdir -p "$RPMBUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

# Copy staged files to SOURCES for the spec to reference
cp -a "$STAGING_DIR/usr" "$RPMBUILD_DIR/SOURCES/"

# Generate spec file
cat > "$RPMBUILD_DIR/SPECS/${PKG_NAME}.spec" <<EOF
Name:           ${PKG_NAME}
Version:        ${VERSION}
Release:        1
Summary:        Markdown viewer with GFM support and Mermaid chart rendering
License:        MIT
URL:            https://github.com/aaddrick/selkie

# Zig already stripped the binary
%define __strip /bin/true
%define debug_package %{nil}

# We provide the full file list — skip automatic dependency detection
AutoReqProv:    no

Requires:       libX11
Requires:       mesa-libGL
Requires:       libXcursor
Requires:       libXext
Requires:       libXfixes
Requires:       libXi
Requires:       libXinerama
Requires:       libXrandr
Requires:       libXrender
Requires:       libglvnd-egl
Requires:       libwayland-client
Requires:       libxkbcommon
Requires:       glibc
Recommends:     zenity

%description
Selkie is a Zig-based GUI markdown viewer with GitHub Flavored Markdown
support, native Mermaid chart rendering, and theming.

%install
mkdir -p %{buildroot}/usr
cp -a ${RPMBUILD_DIR}/SOURCES/usr/* %{buildroot}/usr/

%files
%defattr(0644,root,root,0755)
%attr(0755,root,root) /usr/bin/selkie
/usr/share/selkie/
/usr/share/applications/io.github.aaddrick.selkie.desktop
/usr/share/metainfo/io.github.aaddrick.selkie.metainfo.xml
/usr/share/man/man1/selkie.1*
/usr/share/icons/hicolor/

%post
update-desktop-database /usr/share/applications &>/dev/null || true
update-mime-database /usr/share/mime &>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor &>/dev/null || true

%postun
update-desktop-database /usr/share/applications &>/dev/null || true
update-mime-database /usr/share/mime &>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor &>/dev/null || true
EOF

rpmbuild -bb \
    --define "_topdir $RPMBUILD_DIR" \
    --define "_arch $RPM_ARCH" \
    --target "$RPM_ARCH" \
    "$RPMBUILD_DIR/SPECS/${PKG_NAME}.spec"

# Copy result to working directory
RPM_FILE=$(find "$RPMBUILD_DIR/RPMS" -name "*.rpm" | head -1)
cp "$RPM_FILE" "./${PKG_NAME}-${VERSION}-1.${RPM_ARCH}.rpm"
rm -rf "$RPMBUILD_DIR"

echo "Built: ${PKG_NAME}-${VERSION}-1.${RPM_ARCH}.rpm"
