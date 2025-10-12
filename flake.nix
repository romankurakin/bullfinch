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
          ];

          shellHook = ''
            echo "Bullfinch development environment"
            echo "Zig version: $(zig version)"
            echo "QEMU ARM64 version: $(qemu-system-aarch64 --version | head -n 1)"
            echo "QEMU RISC-V version: $(qemu-system-riscv64 --version | head -n 1)"
            echo "Just version: $(just --version)"
          '';
        };
      });
}