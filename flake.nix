{
  description = "PX4 autopilot: firmware, SITL and development shell";

  inputs = {
    # PX4 builds from its submodules (NuttX, MAVLink, ...), so the flake
    # source must include them.
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      px4For =
        system:
        import ./default.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          src = self;
          rev = self.rev or self.dirtyRev;
          inherit (self) lastModified;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          px4 = px4For system;
        in
        {
          default = px4.sitl;
          inherit (px4) sitl fmu-v6x astyle;
          python = px4.pythonEnv;
        }
      );

      # Every board by make target name: nix build .#px4_fmu-v5x_default
      legacyPackages = forAllSystems (system: (px4For system).boards);

      devShells = forAllSystems (system: {
        default = import ./shell.nix { px4 = px4For system; };
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
