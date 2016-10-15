let
  pkgs = import <nixpkgs> { };

  ghcPackages = pkgs.haskellPackages.ghcWithHoogle (p: with p; [
    ghc-gc-tune
    cabal-install
    hindent
    ghc-mod
    hdevtools
    stylish-haskell
    cabal2nix
    ghcid

    ipprint
    pretty-show

    vector-algorithms
    vector

    hspec
    criterion
    weigh
  ]);

in

with pkgs;

runCommand "dummy" {
  buildInputs = [
    ghcPackages
    pkgs.go_1_7
    gnuplot
  ];
  shellHook = ''
    export NIX_GHC="${ghcPackages}/bin/ghc"
    export NIX_GHCPKG="${ghcPackages}/bin/ghc-pkg"
    export NIX_GHC_DOCDIR="${ghcPackages}/share/doc/ghc/html"
    export NIX_GHC_LIBDIR=$( $NIX_GHC --print-libdir )
  '';
} ""
