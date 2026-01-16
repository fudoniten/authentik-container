{
  description = "Authentik running in a container";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.11";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      nixosModules = rec {
        default = authentikContainer;
        authentikContainer = { ... }: {
          imports = [ arion.nixosModules.arion ./authentik-container.nix ];
        };
      };

      # Basic syntax and evaluation checks
      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          # Check that the module evaluates without errors
          module-syntax = pkgs.runCommand "check-authentik-module" {} ''
            echo "Checking authentik-container module syntax..."
            ${pkgs.nix}/bin/nix-instantiate --eval --strict \
              --expr 'let lib = (import ${nixpkgs} { system = "${system}"; }).lib; in lib.evalModules { modules = [ ${./authentik-container.nix} ]; }' \
              > /dev/null
            echo "Module syntax check passed" > $out
          '';

          # Check that the flake is properly formatted
          flake-syntax = pkgs.runCommand "check-flake-syntax" {} ''
            echo "Checking flake.nix syntax..."
            ${pkgs.nix}/bin/nix-instantiate --parse ${./flake.nix} > /dev/null
            echo "Flake syntax check passed" > $out
          '';
        }
      );
    };
}
