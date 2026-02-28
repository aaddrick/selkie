# Installation

## APT Repository (Debian/Ubuntu)

Add the repository for automatic updates:

```bash
# Add the GPG key
curl -fsSL https://aaddrick.github.io/selkie/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/selkie.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/selkie.gpg arch=amd64,arm64] https://aaddrick.github.io/selkie stable main" | sudo tee /etc/apt/sources.list.d/selkie.list

# Update and install
sudo apt update
sudo apt install selkie
```

Updates install automatically with `sudo apt upgrade`.

## DNF Repository (Fedora/RHEL)

```bash
# Add the repository
sudo curl -fsSL https://aaddrick.github.io/selkie/rpm/selkie.repo -o /etc/yum.repos.d/selkie.repo

# Install
sudo dnf install selkie
```

Updates install automatically with `sudo dnf upgrade`.

## AUR (Arch Linux)

The [`selkie`](https://aur.archlinux.org/packages/selkie) package builds from source:

```bash
# Using yay
yay -S selkie

# Or using paru
paru -S selkie
```

## AppImage

Download the latest `.AppImage` from the [Releases page](https://github.com/aaddrick/selkie/releases):

```bash
chmod +x selkie-*-x86_64.AppImage
./selkie-*-x86_64.AppImage file.md
```

## Nix

```bash
nix run github:aaddrick/selkie
```

Or add to your flake inputs:

```nix
{
  inputs.selkie.url = "github:aaddrick/selkie";
}
```

> **Note:** The Nix build currently requires `--impure` because Zig fetches dependencies at build time. Hermetic builds via `zig2nix` are planned.

## Pre-built Packages

Download `.deb`, `.rpm`, or `.AppImage` files directly from the [Releases page](https://github.com/aaddrick/selkie/releases). Both `amd64` and `arm64` architectures are available.

## Building from Source

See [BUILDING.md](BUILDING.md).
