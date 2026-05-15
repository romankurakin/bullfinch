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
            just
            llvm
            prek
            qemu
          ];

          shellHook = ''
            echo "Bullfinch development environment"
            if command -v rustc >/dev/null; then
              echo "$(rustc --version)"
            else
              echo "install rustup and run rustup show"
            fi
            if command -v cargo >/dev/null; then
              echo "$(cargo --version)"
            else
              echo "install rustup and run rustup show"
            fi
            echo "$(just --version)"
            echo "$(qemu-system-aarch64 --version | head -1)"
            echo "LLVM: $(llvm-config --version)"
          '';
        };
      });
}
