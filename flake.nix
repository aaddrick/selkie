{
  description = "Selkie — Markdown viewer with GFM support and Mermaid chart rendering";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.selkie = pkgs.stdenv.mkDerivation {
          pname = "selkie";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = with pkgs; [
            zig_0_14
            pkg-config
            wayland-scanner
          ];

          buildInputs = with pkgs; [
            libGL
            libxkbcommon
            wayland
            wayland-protocols
            xorg.libX11
            xorg.libXcursor
            xorg.libXext
            xorg.libXfixes
            xorg.libXi
            xorg.libXinerama
            xorg.libXrandr
            xorg.libXrender
          ];

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            runHook preBuild
            # NOTE: Zig fetches raylib-zig at build time, which the Nix sandbox blocks.
            # Options to fix this:
            #   1. Use zig2nix to create a fixed-output derivation for deps (recommended)
            #   2. Pre-fetch deps and point ZIG_LOCAL_CACHE_DIR at them
            #   3. Use `nix build --impure` for development (not recommended for production)
            # For now, this flake works with `nix build --impure .#selkie` or in devShell.
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            zig build -Doptimize=ReleaseSafe --prefix "$out"
            runHook postBuild
          '';

          # Skip default install — zig build --prefix handles it
          dontInstall = true;

          meta = with pkgs.lib; {
            description = "Markdown viewer with GFM support and Mermaid chart rendering";
            homepage = "https://github.com/aaddrick/selkie";
            license = licenses.mit;
            platforms = platforms.linux;
            mainProgram = "selkie";
          };
        };

        packages.default = self.packages.${system}.selkie;

        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.selkie ];
          packages = with pkgs; [
            zig_0_14
          ];
        };
      });
}
