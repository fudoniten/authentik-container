{
  description = "Authentik running in a container";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.11";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }: {
    nixosModules = rec {
      default = authentikContainer;
      authentikContainer = { ... }: {
        imports = [ arion.nixosModules.arion ./authentik-container.nix ];
      };
    };
  };
}
