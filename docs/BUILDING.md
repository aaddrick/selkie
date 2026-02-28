# Building from Source

## Requirements

- [Zig 0.14.1](https://ziglang.org/download/) (stable)
- System libraries (for raylib):
  - X11: `libx11-dev`, `libxcursor-dev`, `libxext-dev`, `libxfixes-dev`, `libxi-dev`, `libxinerama-dev`, `libxrandr-dev`, `libxrender-dev`
  - Wayland: `libwayland-dev`, `wayland-scanner++`, `libxkbcommon-dev`
  - GL: `libegl-dev`, `libgl-dev`

### Ubuntu/Debian

```bash
sudo apt install libwayland-dev wayland-scanner++ libx11-dev libxcursor-dev \
  libxext-dev libxfixes-dev libxi-dev libxinerama-dev libxrandr-dev \
  libxrender-dev libxkbcommon-dev libegl-dev libgl-dev
```

### Fedora

```bash
sudo dnf install wayland-devel wayland-protocols-devel libX11-devel \
  libXcursor-devel libXext-devel libXfixes-devel libXi-devel \
  libXinerama-devel libXrandr-devel libXrender-devel libxkbcommon-devel \
  mesa-libEGL-devel mesa-libGL-devel
```

### Arch

```bash
sudo pacman -S wayland wayland-protocols libx11 libxcursor libxext \
  libxfixes libxi libxinerama libxrandr libxrender libxkbcommon libglvnd mesa
```

## Build

```bash
zig build                                # Debug build
zig build -Doptimize=ReleaseSafe         # Release build
zig build test                           # Run tests
```

## Install

```bash
# System-wide
sudo zig build -Doptimize=ReleaseSafe --prefix /usr/local

# Staged (for packaging)
zig build -Doptimize=ReleaseSafe --prefix staging/usr
```

## Optional Dependencies

- **zenity** — enables the native file-open dialog (`Ctrl+O`)
