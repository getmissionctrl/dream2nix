{
  lib,
  pkgs,
  runCommand,
  stdenv,
  writeText,

  # dream2nix inputs
  builders,
  externals,
  node2nix ? externals.node2nix,
  utils,
  ...
}:

{
  # funcs
  getDependencies,
  getSource,
  buildPackageWithOtherBuilder,

  # attributes
  buildSystemAttrs,
  dependenciesRemoved,
  mainPackageName,
  mainPackageVersion,
  packageVersions,
  

  # overrides
  packageOverrides ? {},

  # custom opts:
  standalonePackageNames ? [],
  ...
}@args:

let

  b = builtins;

  isCyclic = name: version:
    b.elem name standalonePackageNames
    ||
      (dependenciesRemoved ? "${name}"
      && dependenciesRemoved."${name}" ? "${version}");

  mainPackageKey =
    "${mainPackageName}#${mainPackageVersion}";

  nodejsVersion = buildSystemAttrs.nodejsVersion;

  nodejs =
    pkgs."nodejs-${builtins.toString nodejsVersion}_x"
    or (throw "Could not find nodejs version '${nodejsVersion}' in pkgs");

  nodeSources = runCommand "node-sources" {} ''
    tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
    mv node-* $out
  '';

  allPackages =
    lib.mapAttrs
      (name: versions:
        lib.genAttrs
          versions
          (version:
            if isCyclic name version then
              makeCombinedPackage name version
            else
              makePackage name version))
      packageVersions;
  
  makeCombinedPackage = name: version:
    let
      built =
        buildPackageWithOtherBuilder {
          inherit name version;
          builder = builders.nodejs.node2nix;
          inject =
            lib.optionalAttrs (dependenciesRemoved ? "${name}"."${version}") {
              "${name}"."${version}" =
                dependenciesRemoved."${name}"."${version}";
            };
        };
    in
      built.package;

  makePackage = name: version:
    let

      deps = getDependencies name version;

      pkg =
        # b.trace (lib.attrNames allPackages)
        (stdenv.mkDerivation rec {

          packageName = name;
        
          pname = utils.sanitizeDerivationName name;

          inherit version;

          src = getSource name version;

          buildInputs = [ nodejs nodejs.python ];

          ignoreScripts = false;

          inherit nodeSources;

          dependencies_json = writeText "dependencies.json"
            (b.toJSON 
              (lib.listToAttrs
                (b.map
                  (dep: lib.nameValuePair dep.name dep.version)
                  deps)));

          nodeDeps =
            lib.forEach
              deps
              (dep: allPackages."${dep.name}"."${dep.version}" );

          dontUnpack = true;

          installPhase = ''
            runHook preInstall

            nodeModules=$out/lib/node_modules

            mkdir -p $nodeModules

            cd $TMPDIR

            unpackFile ${src}

            # Make the base dir in which the target dependency resides first
            mkdir -p "$(dirname "$nodeModules/${packageName}")"

            # install source
            if [ -f "${src}" ]
            then
                # Figure out what directory has been unpacked
                packageDir="$(find . -maxdepth 1 -type d | tail -1)"

                # Restore write permissions
                find "$packageDir" -type d -exec chmod u+x {} \;
                chmod -R u+w "$packageDir"

                # Move the extracted tarball into the output folder
                mv "$packageDir" "$nodeModules/${packageName}"
            elif [ -d "${src}" ]
            then
                strippedName="$(stripHash ${src})"

                # Restore write permissions
                chmod -R u+w "$strippedName"

                # Move the extracted directory into the output folder
                mv "$strippedName" "$nodeModules/${packageName}"
            fi

            # repair 'link:' -> 'file:'
            mv $nodeModules/${packageName}/package.json $nodeModules/${packageName}/package.json.old
            cat $nodeModules/${packageName}/package.json.old | sed 's!link:!file\:!g' > $nodeModules/${packageName}/package.json
            rm $nodeModules/${packageName}/package.json.old

            # symlink dependency packages into node_modules
            for dep in $nodeDeps; do
              if [ -e $dep/lib/node_modules ]; then
                for module in $(ls $dep/lib/node_modules); do
                  if [[ $module == @* ]]; then
                    for submodule in $(ls $dep/lib/node_modules/$module); do
                      mkdir -p $nodeModules/${packageName}/node_modules/$module
                      echo "ln -s $dep/lib/node_modules/$module/$submodule $nodeModules/${packageName}/node_modules/$module/$submodule"
                      ln -s $dep/lib/node_modules/$module/$submodule $nodeModules/${packageName}/node_modules/$module/$submodule
                    done
                  else
                    mkdir -p $nodeModules/${packageName}/node_modules/
                    echo "ln -s $dep/lib/node_modules/$module $nodeModules/${packageName}/node_modules/$module"
                    ln -s $dep/lib/node_modules/$module $nodeModules/${packageName}/node_modules/$module
                  fi
                done
              fi
            done

            export NODE_PATH="$NODE_PATH:$nodeModules/${packageName}/node_modules"
            cd "$nodeModules/${packageName}"

            export HOME=$TMPDIR

            # delete package-lock.json as it can lead to conflicts
            rm -f package-lock.json

            # fix malformed dependency versions in package.json
            cp package.json package.json.bak
            python ${./fix-package-lock.py} $dependencies_json package.json

            flags=("--offline" "--production" "--nodedir=$nodeSources")
            if [ -n "$ignoreScripts" ]; then
              flags+=("--ignore-scripts")
            fi

            npm "''${flags[@]}" install

            # Create symlink to the deployed executable folder, if applicable
              if [ -d "$nodeModules/.bin" ]
              then
                ln -s $nodeModules/.bin $out/bin
              fi

              # Create symlinks to the deployed manual page folders, if applicable
              if [ -d "$nodeModules/${packageName}/man" ]
              then
                  mkdir -p $out/share
                  for dir in "$nodeModules/${packageName}/man/"*
                  do
                      mkdir -p $out/share/man/$(basename "$dir")
                      for page in "$dir"/*
                      do
                          ln -s $page $out/share/man/$(basename "$dir")
                      done
                  done
              fi

            runHook postInstall
          '';
        });
    in
      (utils.applyOverridesToPackage packageOverrides pkg name);

  package = allPackages."${mainPackageName}"."${mainPackageVersion}";

in
{

  inherit package allPackages;
    
}