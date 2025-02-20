# TODO: try on macmini
# TODO: add support for revng-qa

{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Use poetry2nix for Python dependencies
    poetry2nix.url = "github:nix-community/poetry2nix";
  };

  outputs = { self, nixpkgs, poetry2nix }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let

          # Enable Python 2.7. The version of QEMU we're using still needs it.
          pkgs = import nixpkgs {
            inherit system;
            config.permittedInsecurePackages = [ "python-2.7.18.8" ];
          };

          # Adopt:
          # * clang as a compiler
          # * libc++ as C++ standard library
          # * mold as linker
          stdenv = (pkgs.useMoldLinker pkgs.llvmPackages_16.libcxxStdenv);

          # Use a fake npm project to specify JavaScript dependencies
          revngJavascriptDependencies = pkgs.buildNpmPackage rec {
            name = "revng";
            npmFlags = [ "--legacy-peer-deps" ];
            makeCacheWritable = true;
            src = ./revng-js-dependencies;
            dontNpmBuild = true;
            npmDepsHash = "sha256-8w/ss3DJlo3Mw+Zi6jJxo/3p8I6MDNXSahwdHKNB+Ts=";
          };

          # Import from poetry2nix
          inherit (poetry2nix.lib.mkPoetry2Nix { inherit pkgs; }) mkPoetryApplication overrides;

          revngPythonDependencies = mkPoetryApplication {
            projectDir = ./revng-python-dependencies;
            overrides =
              let
                addBuildInputs = package: list: package.overridePythonAttrs (
                  old: {
                    buildInputs = (old.buildInputs or [ ]) ++ list;
                  }
                );
              in
              overrides.withDefaults
                (self: super: {
                  # Various fixes for packages having issues with poetry
                  mkdocs-graphviz = addBuildInputs super.mkdocs-graphviz [ super.setuptools ];
                  grandiso = addBuildInputs super.grandiso [ super.setuptools ];
                  python-idb = addBuildInputs super.python-idb [ super.setuptools ];
                  vivisect-vstruct-wb = addBuildInputs super.vivisect-vstruct-wb [ super.setuptools ];
                  marko = addBuildInputs super.marko [ super.pdm-backend ];
                  mkdocs-get-deps = addBuildInputs super.mkdocs-get-deps [ super.hatchling ];
                  flake8-builtins = addBuildInputs super.flake8-builtins [ super.hatchling ];
                  flake8-eradicate = addBuildInputs super.flake8-eradicate [ super.poetry-core ];

                  flake8-return = super.flake8-return.overridePythonAttrs (
                    old: {
                      buildInputs = (old.buildInputs or [ ]) ++ [ super.poetry-core ];
                      postPatch = ''
                        substituteInPlace pyproject.toml --replace "poetry.masonry" "poetry.core.masonry"
                      '';
                    }
                  );

                  flake8-breakpoint = super.flake8-breakpoint.overridePythonAttrs (
                    old: {
                      buildInputs = (old.buildInputs or [ ]) ++ [ super.poetry-core ];
                      postPatch = ''
                        substituteInPlace pyproject.toml --replace "poetry.masonry" "poetry.core.masonry"
                      '';
                    }
                  );

                  hexdump = super.hexdump.overridePythonAttrs (
                    old: {
                      postPatch = ''
                        cd ..
                      '';
                    }
                  );

                  # Add libyaml for C implementation of YAML for greater performance
                  pyyaml = addBuildInputs super.pyyaml [ pkgs.libyaml ];

                  # Do not bother with -Werror for mypy
                  mypy = super.mypy.overridePythonAttrs (
                    old: {
                      postPatch = ''
                        substituteInPlace mypyc/build.py --replace '"-Werror",' ""
                      '';
                    }
                  );

                  cmakelang = super.cmakelang.overridePythonAttrs (
                    old: {
                      buildInputs = (old.buildInputs or [ ]) ++ [ super.setuptools ];
                      patches = [
                        (pkgs.writeText "inline-patch.patch" ''
                          --- pypi/setup.py
                          +++ pypi/setup.py
                          @@ -62,6 +62,7 @@ setup(
                               install_requires=["six>=1.13.0"]
                           )

                          +"""
                           setup(
                               name="cmake-annotate",
                               packages=[],
                          @@ -155,3 +156,4 @@ setup(
                               include_package_data=True,
                               install_requires=["cmakelang>={}".format(VERSION)]
                           )
                          +"""
                        '')
                      ];
                      postPatch = ''
                        echo make
                        substituteInPlace setup.py --replace "cmakelang/doc/README.rst" "README.rst"
                      '';
                    }
                  );
                });
          };

          #
          # Build C++ dependencies using our stdenv
          #
          boost-test = (
            pkgs.lib.fix (self:
              pkgs.callPackage "${nixpkgs}/pkgs/development/libraries/boost/1.81.nix" {
                stdenv = pkgs.llvmPackages_16.libcxxStdenv;

                # Use the right version of boost-build.
                # This has been copied from nixpkgs.
                boost-build = pkgs.boost-build.override { useBoost = self; };
              }
            )
          ).overrideAttrs (oldAttrs: {
            # Build only the libraries we're interseted in
            configureFlags = oldAttrs.configureFlags ++ [ "--with-libraries=test" ];
          });

          aws-crt-cpp = (pkgs.callPackage "${nixpkgs}/pkgs/development/libraries/aws-crt-cpp/default.nix" {
            stdenv = stdenv;
          });

          aws-sdk-cpp = (pkgs.callPackage "${nixpkgs}/pkgs/development/libraries/aws-sdk-cpp/default.nix" {
            stdenv = stdenv;

            aws-crt-cpp = aws-crt-cpp;

            # These are macOS-specific but required
            AudioToolbox = null;
            CoreAudio = null;

            # Only build the APIs we're interested in
            apis = [ "s3" ];
          }).overrideAttrs (oldAttrs: {
            cmakeFlags = oldAttrs.cmakeFlags ++ [
              "-DENABLE_TESTING=OFF"
              "-DFORCE_CURL=ON"
              "-DENABLE_UNITY_BUILD=OFF"
              "-DENABLE_RTTI=OFF"
              "-DCPP_STANDARD=20"
            ];
          });

        in
        {



          # Build our LLVM fork
          llvm = stdenv.mkDerivation {
            name = "llvm";

            src = pkgs.fetchFromGitHub {
              owner = "revng";
              repo = "llvm-project";
              rev = "890ac9b43d65bde1d4e4f28bbe6a56237912a954";
              sha256 = "sha256-hmqR3i8BysO/PIt3Z+VmDMwFNPdbjwnHayBJaGemwL4=";
            };

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              python3
            ];

            cmakeFlags = [
              "-GNinja"

              "-DCMAKE_INSTALL_BINDIR=libexec"

              "-DLLVM_INSTALL_UTILS=ON"
              "-DLLVM_ENABLE_DUMP=ON"
              "-DLLVM_ENABLE_TERMINFO=OFF"
              "-DCMAKE_CXX_STANDARD=20"
              "-DLLVM_ENABLE_Z3_SOLVER=OFF"
              "-DLLVM_ENABLE_ZLIB=ON"
              "-DLLVM_ENABLE_LIBEDIT=ON"
              "-DLLVM_ENABLE_LIBXML2=OFF"
              "-DLLVM_ENABLE_ZSTD=OFF"

              "-DBUILD_SHARED_LIBS=ON"
              "-DLLVM_ENABLE_PROJECTS=clang;mlir"
              "-DLLVM_TARGETS_TO_BUILD=AArch64;ARM;Mips;SystemZ;X86"
              "-DCMAKE_CXX_FLAGS=-Wno-global-constructors"
            ];

            preConfigure = "cd llvm";

          };

          # Build our fork of QEMU
          qemu = pkgs.llvmPackages_16.stdenv.mkDerivation {
            name = "qemu";

            src = pkgs.fetchurl {
              url = "https://github.com/revng/qemu/archive/refs/heads/develop.tar.gz";
              sha256 = "sha256-UyDsI+JfjaBJdrHfC1KtXa/xQK1CtAEgasCf6jTMPfA";
            };

            nativeBuildInputs = with pkgs; [
              python2
              pkg-config
              zlib
              glib
              clang_16
              llvm_16
            ];

            enableParallelBuilding = true;

            configureFlags = [
              "--target-list=arm-libtinycode,arm-linux-user,aarch64-libtinycode,aarch64-linux-user,i386-libtinycode,i386-linux-user,mips-libtinycode,mips-linux-user,mipsel-libtinycode,mipsel-linux-user,s390x-libtinycode,s390x-linux-user,x86_64-libtinycode,x86_64-linux-user"
              "--disable-werror"
              "--enable-llvm-helpers"
              "--disable-kvm"
              "--without-pixman"
              "--disable-tools"
              "--disable-system"
              "--disable-libnfs"
              "--disable-vde"
              "--disable-gnutls"
              "--disable-smartcard-nss"
              "--disable-uuid"
              "--disable-cap-ng"
            ];

            preInstall = ''
              mkdir -p $out/include
              mkdir -p $out/lib
            '';
          };

          revng-qa = stdenv.mkDerivation {
            name = "revng-qa";

            src = pkgs.fetchurl {
              url = "https://github.com/revng/revng-qa/archive/62e18aa.tar.gz";
              sha256 = "sha256-eMpTCHBU7IqztxrhC928oFOivC0eyOomXHA8KhSyl0o=";
            };

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              (python312.withPackages (ps: with ps; [
                jinja2
                pyyaml
              ]))
            ];

            cmakeFlags = [
              "-GNinja"
            ];

          };

          "test/revng-qa" = stdenv.mkDerivation {
            name = "test/revng-qa";

            unpackPhase = "true";

            nativeBuildInputs = with pkgs; [
              ((import nixpkgs) {
                localSystem = { inherit system; };
                crossSystem = { config = "mips-unknown-linux-musl"; };
              }).stdenv.cc
              self.packages.${system}.revng-qa
              (python312.withPackages (ps: with ps; [
                jinja2
                pyyaml
              ]))
            ];

            installPhase = ''
              mkdir -p "$out/bin"
              python3 ${self.packages.${system}.revng-qa}/libexec/revng/test-configure --help &> $out/hello.txt || true
            '';

          };

          # "test/revng-qa" = derivation {
          #   name = "hello-derivation";
          #   builder = "${pkgs.runtimeShell}";
          #   args = [ "-c" ''
          #     export PATH="${pkgs.python3}/bin:${pkgs.coreutils}/bin:$PATH"
          #     mkdir -p $out
          #     (
          #     echo "${self.packages.${system}.revng-qa}"
          #     python3 ${self.packages.${system}.revng-qa}/libexec/revng/test-configure --help
          #     pwd
          #     ) &> $out/hello.txt
          #   '' ];
          #   system = "${system}";
          # };

          # Build revng
          revng = stdenv.mkDerivation {
            name = "revng";

            src = pkgs.fetchurl {
              url = "https://github.com/revng/revng/archive/79d7c21.tar.gz";
              sha256 = "sha256-d0t2vs9n2JgUmT0IwRTMMO4SCAfz5icO0+xJVzS1MQI=";
            };

            nativeBuildInputs = with pkgs; [
              aws-sdk-cpp
              boost-test
              cmake
              codespell
              git
              libarchive
              ninja
              nodejs
              revngJavascriptDependencies
              revngPythonDependencies
              self.packages.${system}.llvm
              self.packages.${system}.qemu
              zlib
            ];

            cmakeFlags = [
              "-GNinja"
              "-DLLVM_DIR=${self.packages.${system}.llvm}/lib/cmake/llvm"
            ];

          };

        });
    };
}
