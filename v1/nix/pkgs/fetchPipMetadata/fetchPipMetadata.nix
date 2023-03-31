# fetchPip downloads python packages specified by executing
#   `pip download` on a source tree, or a list of requirements.
# This fetcher requires a maximum date 'pypiSnapshotDate' being specified.
# The result will be the same as if `pip download` would have been executed
#   at the point in time specified by pypiSnapshotDate.
# This is ensured by putting pip behind a local proxy filtering the
#   api responses from pypi.org to only contain files for which the
#   release date is lower than the specified pypiSnapshotDate.
# TODO: ignore if packages are yanked
# TODO: for pypiSnapshotDate only allow timestamp or format 2023-01-01
# TODO: Error if pypiSnapshotDate points to the future
{
  buildPackages,
  lib,
  stdenv,
  # Use the nixpkgs default python version for the proxy script.
  # The python version select by the user below might be too old for the
  #   dependencies required by the proxy
  python3,
}: {
  # Specify the python version for which the packages should be downloaded.
  # Pip needs to be executed from that specific python version.
  # Pip accepts '--python-version', but this works only for wheel packages.
  python,
  # list of strings of requirements.txt entries
  requirementsList ? [],
  # list of requirements.txt files
  requirementsFiles ? [],
  pipFlags ? [],
  name ? "pip-metadata",
  nativeBuildInputs ? [],
  # maximum release date for packages
  pypiSnapshotDate ?
    throw ''
      'pypiSnapshotDate' must be specified for fetchPip.
      Choose any date from the past.
      Example value: "2023-01-01"
    '',
}: let
  # We use nixpkgs python3 to run mitmproxy, see function parameters
  pythonWithMitmproxy =
    python3.withPackages
    (ps: [ps.mitmproxy ps.dateutil]);

  # We use the user-selected python to run pip and friends, this ensures
  # that version-related markers are resolved correctly.
  pythonWithPackaging =
    python.withPackages
    (ps: [ps.packaging ps.certifi ps.dateutil ps.pip]);

  pythonMajorAndMinorVer =
    lib.concatStringsSep "."
    (lib.sublist 0 2 (lib.splitString "." python.version));

  # A fixed output derivation containing all downloaded packages.
  # each single file is located inside a directory named like the package.
  # Example:
  #   "$out/werkzeug" will contain "Werkzeug-0.14.1-py2.py3-none-any.whl"
  # Each directory only ever contains a single file
  pipDownload = stdenv.mkDerivation (finalAttrs: {
    # An invalidation hash is embedded into the `name`.
    # This will prevent `forgot to update the hash` scenarios, as any change
    #   in the derivaiton name enforces a re-build.
    inherit name;

    # disable some phases
    dontUnpack = true;
    dontInstall = true;
    dontFixup = true;

    # build inputs
    nativeBuildInputs = nativeBuildInputs ++ [pythonWithMitmproxy];

    # python scripts
    filterPypiResponsesScript = ../fetchPip/filter-pypi-responses.py;
    buildScript = ./fetchPipMetadata.py;

    # the python interpreter used to run the build script
    inherit pythonWithPackaging;

    # the python interpreter used to run the proxy script
    inherit pythonWithMitmproxy;

    # convert pypiSnapshotDate to string and integrate into finalAttrs
    pypiSnapshotDate = builtins.toString pypiSnapshotDate;

    # add some variables to the derivation to integrate them into finalAttrs
    inherit
      requirementsFiles
      requirementsList
      ;

    # prepare flags for `pip download`
    pipFlags = lib.concatStringsSep " " pipFlags;
    # - Execute `pip download` through the filtering proxy.
    # - optionally add a file to the FOD containing metadata of the packages involved
    buildPhase = ''
      $pythonWithPackaging/bin/python $buildScript
    '';
  });
in
  pipDownload
