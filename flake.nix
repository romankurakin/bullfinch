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
            zig
            qemu
            just
            llvm
          ];

          shellHook = ''
            echo "Bullfinch development environment"
            echo "  Zig: $(zig version)"
            echo "  QEMU: $(qemu-system-aarch64 --version | head -1)"
          '';
        };
      });
}