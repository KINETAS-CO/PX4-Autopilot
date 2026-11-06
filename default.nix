# Nix packages for PX4-Autopilot.
#
#   nix-build -A sitl                    # build/px4_sitl_default equivalent
#   nix-build -A fmu-v6x                 # px4_fmu-v6x_default firmware
#   nix-build -A boards.px4_fmu-v5x_default
#
# The flake (flake.nix) imports this file; without arguments nixpkgs is the
# revision locked in flake.lock, so flake and non-flake builds match.
let
  lock = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
  pinnedPkgs = import (fetchTarball {
    url = "https://github.com/${lock.owner}/${lock.repo}/archive/${lock.rev}.tar.gz";
    sha256 = lock.narHash;
  }) { };
in
{
  pkgs ? pinnedPkgs,
  # PX4 source tree, with submodules checked out. Defaults to the
  # git-tracked files of this checkout (dirty edits included).
  src ? null,
  # Commit the source was taken from ("<hash>" or "<hash>-dirty"), which the
  # firmware reports as its git hash (ver all, .px4 git_hash). Defaults to
  # this checkout's HEAD.
  rev ? null,
  # Commit time (Unix seconds), used as SOURCE_DATE_EPOCH for the build
  # time embedded in the firmware. Defaults to this checkout's HEAD.
  lastModified ? null,
  # Release tag the build reports (ver all, MAVLink AUTOPILOT_VERSION).
  # PX4 derives it from `git describe`; bump it when main is tagged.
  version ? "1.18.0-beta1",
}:

let
  inherit (pkgs) lib;

  source =
    if src != null then
      src
    else
      lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.gitTrackedWith { recurseSubmodules = true; } ./.;
      };

  # A dirty checkout has rev 000...0 and the HEAD hash in dirtyRev.
  checkout = builtins.fetchGit ./.;
  sourceRev =
    if rev != null then
      rev
    else if checkout.dirtyRev or null != null then
      checkout.dirtyRev
    else
      checkout.rev;
  commit = lib.removeSuffix "-dirty" sourceRev;
  sourceDateEpoch = if lastModified != null then lastModified else checkout.lastModified;

  # Matches the GNU Arm toolchain major version in the px4-dev container
  # and PX4 CI.
  armToolchain = pkgs.gcc-arm-embedded-13;

  # Tools/setup/requirements.txt, with the versions nixpkgs lacks or has
  # too new.
  python = pkgs.python3.override {
    self = python;
    packageOverrides = pyself: pysuper: {
      # PX4's templates use the empy 3 API; empy 4 is incompatible.
      empy = pyself.buildPythonPackage rec {
        pname = "empy";
        version = "3.3.4";
        pyproject = true;
        src = pyself.fetchPypi {
          inherit pname version;
          hash = "sha256-c6xJeFtgFHnfTqGKfHm8EwSop8NMArlHLPEgauiPAbM=";
        };
        build-system = [ pyself.setuptools ];
        doCheck = false;
      };

      pyros-genmsg = pyself.buildPythonPackage rec {
        pname = "pyros-genmsg";
        version = "0.5.8";
        pyproject = true;
        src = pyself.fetchPypi {
          pname = "pyros_genmsg";
          inherit version;
          hash = "sha256-PBywfZxA+eYIcph+7Jg6rFvbWSDqd5gDA/scRsMI9Hg=";
        };
        build-system = [ pyself.setuptools ];
        doCheck = false;
      };

      pyulog = pyself.buildPythonPackage rec {
        pname = "pyulog";
        version = "1.2.4";
        pyproject = true;
        src = pyself.fetchPypi {
          inherit pname version;
          hash = "sha256-+w7f3k1UW6RvD2+1CGMFR6oCpienkzceCN7/LiaJ66c=";
        };
        build-system = [
          pyself.setuptools
          pyself.setuptools-scm
        ];
        dependencies = [ pyself.numpy ];
        doCheck = false;
      };
    };
  };

  # requirements.txt also lists `future`, a Python 2 shim nothing imports
  # and nixpkgs no longer builds for Python 3.13.
  pythonEnv = python.withPackages (
    ps: with ps; [
      argcomplete
      cerberus
      coverage
      empy
      jinja2
      jsonschema
      kconfiglib
      lark
      lxml
      matplotlib
      numpy
      nunavut
      packaging
      pandas
      pkgconfig
      psutil
      pycryptodome
      pygments
      pymavlink
      pynacl
      pyros-genmsg
      pyserial
      pyulog
      pyyaml
      requests
      setuptools
      six
      sympy
      toml
      wheel
    ]
  );

  # Tools/astyle/check_code_style_all.sh accepts only astyle 2.06 to 3.1.
  astyle = pkgs.stdenv.mkDerivation rec {
    pname = "astyle";
    version = "3.1";
    src = pkgs.fetchurl {
      url = "mirror://sourceforge/astyle/astyle/astyle%20${version}/astyle_${version}_linux.tar.gz";
      hash = "sha256-y8xM+ZYpRTS7VvAl1vGZ6/3oGqTCccy9XuHBoxknRdc=";
    };
    nativeBuildInputs = [ pkgs.cmake ];
    cmakeFlags = [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
    # Its install rule hardcodes /usr/bin.
    installPhase = ''
      install -Dm755 astyle $out/bin/astyle
    '';
    meta = {
      description = "Source code formatter, at the version PX4's style check requires";
      license = lib.licenses.mit;
      mainProgram = "astyle";
    };
  };

  # Tools every PX4 build needs, whatever the board.
  buildTools = [
    pkgs.cmake
    pkgs.ninja
    pkgs.gnumake
    pkgs.git
    pkgs.genromfs
    # flock, which the NuttX apps Makefile locks libapps.a with.
    pkgs.util-linux
    pkgs.xxd
    pythonEnv
  ];

  # The Micro-XRCE-DDS-Client superbuilds git-clone Micro-CDR at build time,
  # which the sandbox forbids. Each client pins its own release.
  microCdr = {
    "Micro-XRCE-DDS-Client" = pkgs.fetchurl {
      url = "https://github.com/eProsima/Micro-CDR/archive/refs/tags/v2.0.1.tar.gz";
      hash = "sha256-vMFlF6zFWlj61tOc+kK6Nljix9D0CK9bGie2NActZLY=";
    };
    "Micro-XRCE-DDS-Client-v3" = pkgs.fetchurl {
      url = "https://github.com/eProsima/Micro-CDR/archive/refs/tags/v2.0.2.tar.gz";
      hash = "sha256-kvKBnyy3aRYjWLb2V3AAzFpYPvnGnROmKO4KvR98PR8=";
    };
  };

  # boards/<vendor>/<model>/<label>.px4board for a make target. The label
  # defaults to "default" (px4_sitl -> boards/px4/sitl/default.px4board).
  boardFiles =
    target:
    let
      parts = lib.splitString "_" target;
      vendor = lib.head parts;
      rest = lib.drop 1 parts;
      boardFile = model: label: source + "/boards/${vendor}/${model}/${label}.px4board";
      labelled =
        lib.length rest > 1
        && builtins.pathExists (boardFile (lib.concatStringsSep "_" (lib.init rest)) (lib.last rest));
      model = lib.concatStringsSep "_" (if labelled then lib.init rest else rest);
      label = if labelled then lib.last rest else "default";
    in
    if !(builtins.pathExists (boardFile model "default")) then
      throw "PX4 target '${target}': no boards/${vendor}/${model}/default.px4board"
    else
      lib.unique [
        (boardFile model "default")
        (boardFile model label)
      ];

  # Build one PX4 make target (`make <target>`) from source.
  mkPx4 =
    target:
    let
      config = lib.concatMapStringsSep "\n" builtins.readFile (boardFiles target);
      hasOption = option: lib.hasInfix "\n${option}" "\n${config}";
      isPosix = hasOption "CONFIG_PLATFORM_POSIX=y";
      isNuttx = !(hasOption "CONFIG_PLATFORM_");
      crossToolchain = lib.findFirst (lib.hasPrefix "CONFIG_BOARD_TOOLCHAIN=") null (
        lib.splitString "\n" config
      );
      buildDir = "build/${target}";
    in
    assert lib.assertMsg (
      isNuttx || (isPosix && crossToolchain == null)
    ) "PX4 target '${target}': only NuttX boards and native POSIX (SITL) boards build with Nix";
    assert lib.assertMsg (
      lib.match "[0-9a-f]{40}" commit != null
    ) "PX4: rev must be a full commit hash, optionally suffixed -dirty; got '${sourceRev}'";
    pkgs.stdenv.mkDerivation {
      pname = "px4-${target}";
      inherit version;
      src = source;

      nativeBuildInputs = buildTools ++ lib.optional isNuttx armToolchain;

      strictDeps = true;

      # Configure the way the top-level Makefile does: the cmake setup hook
      # would point CMAKE_AR and friends at the host binutils, which breaks
      # NuttX cross builds.
      dontUseCmakeConfigure = true;
      dontUseNinjaBuild = true;
      dontUseNinjaInstall = true;

      # Firmware is not a host binary: leave the ELF as the toolchain wrote it.
      dontStrip = isNuttx;
      dontPatchELF = isNuttx;

      env = {
        # The commit time, rather than stdenv's 1980 default, for __DATE__
        # and the .px4 build_time (Tools/px_mkfw.py).
        SOURCE_DATE_EPOCH = toString sourceDateEpoch;
      }
      // lib.optionalAttrs isPosix {
        # SITL's px4 finds its ROMFS through the install prefix, as the .deb
        # package does (cmake/package.cmake).
        NIX_CFLAGS_COMPILE = ''-DPX4_INSTALL_PREFIX="${placeholder "out"}"'';
      };

      postPatch = ''
        patchShebangs --build .

        ${lib.concatStrings (
          lib.mapAttrsToList (client: tarball: ''
            substituteInPlace src/modules/uxrce_dds_client/${client}/cmake/SuperBuild.cmake \
              --replace-fail ${
                lib.escapeShellArg (
                  lib.concatStringsSep "\n" [
                    "        GIT_REPOSITORY"
                    "            https://github.com/eProsima/Micro-CDR.git"
                    "        GIT_TAG"
                    "            \${_microcdr_tag}"
                  ]
                )
              } "        URL ${tarball}"
          '') microCdr
        )}

        # PX4 versions itself with `git describe` and refuses to configure
        # outside a git work tree. The source has no .git, so give it a
        # deterministic one-commit history. A replace ref maps the real
        # commit's hash onto that commit, so HEAD and the release tag can
        # name the real hash and every git query PX4 makes returns it.
        export GIT_AUTHOR_NAME=nix GIT_AUTHOR_EMAIL=nix@localhost
        export GIT_COMMITTER_NAME=nix GIT_COMMITTER_EMAIL=nix@localhost
        export GIT_AUTHOR_DATE="1970-01-01T00:00:01Z" GIT_COMMITTER_DATE="1970-01-01T00:00:01Z"
        git init --quiet
        git commit --quiet --allow-empty --no-gpg-sign -m "PX4-Autopilot ${sourceRev}"
        git update-ref refs/replace/${commit} HEAD
        git update-ref HEAD ${commit}
        git update-ref refs/tags/v${version} ${commit}

        # px_update_git_header.py emits the MAVLink and NuttX versions, which
        # the mavlink module and NuttX boards link against, only when those
        # submodules have a .git. The NuttX tag comes from .gitmodules; their
        # hashes are not available to Nix, so these report synthetic ones.
        for submodule in src/modules/mavlink/mavlink platforms/nuttx/NuttX/nuttx; do
          git -C $submodule init --quiet
          git -C $submodule commit --quiet --allow-empty --no-gpg-sign -m "$submodule for PX4-Autopilot ${sourceRev}"
        done
      '';

      # Submodules come with the source; the check would try to fetch them.
      GIT_SUBMODULES_ARE_EVIL = 1;

      configurePhase = ''
        runHook preConfigure
        cmake -S . -B ${buildDir} -G Ninja \
          -DCONFIG=${target} \
          -DPYTHON_EXECUTABLE=${pythonEnv.interpreter}
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        cmake --build ${buildDir} -- -j$NIX_BUILD_CORES
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
      ''
      + (
        if isPosix then
          ''
            cp -a ${buildDir}/bin ${buildDir}/etc $out/
          ''
        else
          ''
            cp ${buildDir}/${target}.px4 ${buildDir}/${target}.elf $out/
            cp ${buildDir}/${target}.bin $out/ 2>/dev/null || true
          ''
      )
      + ''
        runHook postInstall
      '';

      passthru = { inherit target pythonEnv; };

      meta = {
        description = "PX4 autopilot, ${target}";
        homepage = "https://px4.io";
        license = lib.licenses.bsd3;
        platforms = lib.platforms.linux;
      }
      // lib.optionalAttrs isPosix { mainProgram = "px4"; };
    };

  # Every boards/<vendor>/<model>/<label>.px4board, by make target name.
  targets =
    let
      boardsDir = source + "/boards";
      subdirs =
        dir: lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir));
      labels =
        dir:
        map (lib.removeSuffix ".px4board") (
          lib.filter (lib.hasSuffix ".px4board") (lib.attrNames (builtins.readDir dir))
        );
    in
    lib.concatMap (
      vendor:
      lib.concatMap (
        model: map (label: "${vendor}_${model}_${label}") (labels "${boardsDir}/${vendor}/${model}")
      ) (subdirs "${boardsDir}/${vendor}")
    ) (subdirs boardsDir);
in
{
  inherit
    pkgs
    pythonEnv
    astyle
    armToolchain
    buildTools
    ;

  # Any `make <target>` name, e.g. firmware "px4_fmu-v6c_default".
  firmware = mkPx4;

  # Firmware for every board, by target name; evaluated only on access.
  boards = lib.genAttrs targets mkPx4;

  sitl = mkPx4 "px4_sitl_default";
  fmu-v6x = mkPx4 "px4_fmu-v6x_default";
}
