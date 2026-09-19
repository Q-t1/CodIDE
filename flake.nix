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

    # Only used by `checks` (a throwaway home configuration that proves the
    # module evaluates and builds); the exported module itself does not need it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      flake-utils,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      # The module takes this flake's inputs by closure rather than through a
      # `specialArgs` named `inputs`, so it drops into any consuming flake
      # without colliding with that flake's own module arguments.
      codingIde = import ./modules/coding-ide inputs;
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        formatter = pkgs.nixfmt;

        # `nix flake check` builds the IDE for a dummy user on this system —
        # the cheapest way to catch an option rename in nixvim or Home Manager
        # before a host does. Heavy: it builds Neovim with every plugin, LSP
        # and formatter.
        checks.coding-ide = self.lib.mkExampleHome { inherit system; };
      }
    )
    // {
      homeModules = {
        coding-ide = codingIde;
        default = codingIde;
      };

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
            {
              home = {
                inherit username;
                homeDirectory =
                  if nixpkgs.lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}";
                stateVersion = "26.05";
              };
              programs.home-manager.enable = true;
            }
          ]
          ++ modules;
        }).activationPackage;
    };
}
