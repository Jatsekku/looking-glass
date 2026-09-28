{
  description = "NixOS module for Looking Glass";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      # List of all supported systems
      supportedSystems = nixpkgs.lib.systems.flakeExposed;

      # Function for providing system-specific attributes
      forEachSupportedSystem =
        f:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            # Nixpkgs configured per system
            pkgs = import nixpkgs {
              inherit system;
              # Allow usage of unfree packages
              config.allowUnfree = true;
            };
          }
        );
    in
    {
      nixosModules = rec {
        looking-glass = {
          imports = [ ./looking-glass.nix ];
        };
        default = looking-glass;
      };

      # Set formatter for Nix
      formatter = forEachSupportedSystem ({ pkgs }: pkgs.nixfmt-tree);
    };
}
