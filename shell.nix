# PX4 development shell: `nix-shell`, or `nix develop` with the flake.
#
# Provides what Tools/setup/ubuntu.sh installs, so `make px4_sitl`,
# `make px4_fmu-v6x_default`, `make tests` and `make format` work as
# documented.
{
  px4 ? import ./default.nix { },
}:

let
  inherit (px4) pkgs;
in
pkgs.mkShell {
  packages =
    px4.buildTools
    ++ [
      px4.armToolchain
      px4.astyle
    ]
    ++ (with pkgs; [
      ccache
      clang-tools
      cppcheck
      file
      gdb
      lcov
      libxml2
      rsync
      shellcheck
      screen
      ubootTools
      unzip
      zip
    ]);

  shellHook = ''
    # Keep pip installs from leaking in from ~/.local.
    export PYTHONNOUSERSITE=1
  '';
}
