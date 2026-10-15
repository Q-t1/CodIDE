{
  description = "CodIDE — a terminal IDE (yazi + zellij + nixvim) as a Home Manager module";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Every Neovim plugin is pinned here: there is no runtime plugin manager in
    # the editor (no lazy.nvim, no Mason).
    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `claude` CLI. Deliberately NOT following our nixpkgs: a different nixpkgs
    # changes the store path and loses the upstream cachix cache hits. Taken
    # from this flake (packages.<system>.default) rather than via its overlay,
    # so a consumer needs neither the overlay nor `nixpkgs.config.allowUnfree`
    # — see programs.codingIde.claudeCode in modules/coding-ide/default.nix.
    claude-code.url = "github:sadjow/claude-code-nix";

    # yazi's Catppuccin theme, which the module parses at evaluation time. As a
    # flake input it is fetched (and locked) before evaluation; a fetcher inside
    # the module would make that parse import-from-derivation.
    catppuccin-yazi = {
      url = "github:catppuccin/yazi";
      flake = false;
    };

    # Only used by `checks` (a throwaway home configuration that proves the
    # module evaluates and builds); the exported module itself does not need it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # x86_64-darwin is gone: nixpkgs no longer evaluates for it.
      forAllSystems =
        f:
        lib.genAttrs [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-linux"
        ] (system: f nixpkgs.legacyPackages.${system});

      # The module takes this flake's inputs as a static argument rather than
      # through a `specialArgs` named `inputs`, so it drops into any consuming
      # flake without colliding with that flake's own module arguments.
      # importApply (unlike a bare `import`) records the file, so module-system
      # errors point at it instead of at `<unknown-file>`.
      codingIde = lib.modules.importApply ./modules/coding-ide inputs;
    in
    {
      homeModules = {
        coding-ide = codingIde;
        default = codingIde;
      };

      # A throwaway home configuration with the IDE enabled, built by `checks`.
      # Extra `modules` are a quick way to try an option out.
      lib.mkExampleHome =
        {
          system,
          username ? "codide",
          modules ? [ ],
        }:
        (home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.${system};
          modules = [
            codingIde
            (
              { pkgs, ... }:
              {
                home = {
                  inherit username;
                  homeDirectory =
                    if pkgs.stdenv.hostPlatform.isDarwin then "/Users/${username}" else "/home/${username}";
                  stateVersion = "26.05";
                };
                programs = {
                  home-manager.enable = true;
                  codingIde.enable = true;
                  # The `coding` / `gitview` / `fif` shell functions are zsh's.
                  zsh.enable = true;
                };
              }
            )
          ]
          ++ modules;
        }).activationPackage;

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      checks = forAllSystems (pkgs: {
        # Cheap, so it fails fast before the heavy build below.
        format = pkgs.runCommandLocal "check-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          find ${self} -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';

        # Builds the IDE for a dummy user on this system — the cheapest way to
        # catch an option rename in nixvim or Home Manager before a host does.
        # Heavy: it builds Neovim with every plugin, LSP and formatter.
        coding-ide = self.lib.mkExampleHome { inherit (pkgs.stdenv.hostPlatform) system; };
      });
    };
}
