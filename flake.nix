{
  description = "Bullfinch microkernel development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            cargo
            clippy
            just
            llvm
            qemu
            rustc
            rustfmt
          ];

          shellHook = ''
            echo "Bullfinch development environment"
            echo "Rust: $(rustc --version)"
            echo "Cargo: $(cargo --version)"
            echo "Just: $(just --version)"
            echo "QEMU: $(qemu-system-aarch64 --version | head -1)"
            echo "LLVM: $(llvm-config --version)"
          '';
        };
      });
}
