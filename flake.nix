{
  description = "Bullfinch microkernel development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            just
            zig
            qemu
            llvm
          ];

          shellHook = ''
            # Workaround: Zig's setup hook sets ZIG_GLOBAL_CACHE_DIR to a sandbox path
            # that doesn't exist outside the build. Force override to local directory.
            # Fix pending: https://github.com/NixOS/nixpkgs/pull/479423
            export ZIG_GLOBAL_CACHE_DIR="$PWD/zig-cache"

            echo "Bullfinch development environment"
            echo "Just: $(just --version)"
            echo "Zig: $(zig version)"
            echo "QEMU: $(qemu-system-aarch64 --version | head -1)"
            echo "LLVM: $(llvm-config --version)"
          '';
        };
      });
}