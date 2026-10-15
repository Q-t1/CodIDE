# CodIDE

A terminal IDE, packaged as a single Home Manager module: **yazi** as a file
sidebar, **Neovim** (nixvim — every plugin pinned, no lazy.nvim, no Mason) as
the editor, **zellij** holding the two together, plus **lazygit** and the
`claude` CLI.

```
┌ files ┐┌──────── editor (nvim) ────────┐
│ yazi  ││ [file1] │ [file2] │ [file3] … │  ← barbar tabline
│       ││                               │
└───────┘└───────────────────────────────┘
┌─────────────── terminal ───────────────┐
└────────────────────────────────────────┘
```

Neovim runs with `--listen` on a per-tab socket, so picking a file in yazi
(or in the `fif` / `s` / `S` fuzzy searches) opens it as a buffer in the *same*
Neovim instance instead of a new pane.

Everything is declarative: language servers, formatters and linters come from
nixpkgs on Neovim's PATH — nothing is installed at runtime.

## Use it

Add the flake as an input and import `homeModules.default` into a Home Manager
configuration. Make it follow your nixpkgs so the IDE is built from the same
revision as the rest of your host (and your home-manager, which this flake only
uses for its own `checks`, so your lock file carries one copy):

```nix
{
  inputs.codide = {
    url = "github:Q-t1/CodIDE";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
  };
}
```

```nix
# in a home.nix
{ inputs, ... }:
{
  imports = [ inputs.codide.homeModules.default ];

  programs.codingIde = {
    enable = true;
    clipboardProvider = "pbcopy";
  };
}
```

Nothing else is required: the module pulls its own `claude` build and pins
nixvim's nixpkgs itself, so the importing host needs neither an overlay nor
`nixpkgs.config.allowUnfree`.

Then, in a shell:

| Command          | What it does                                                 |
|------------------|--------------------------------------------------------------|
| `coding [dir]`   | Open the IDE on a directory (a new zellij session, or a tab inside one). A file argument just edits the file. |
| `gitview [dir]`  | A full-screen lazygit tab.                                   |
| `fif <pattern>`  | ripgrep + fzf content search; the pick opens at the matched line in the tab's Neovim. |

Inside the IDE: `Enter` in yazi opens a file in the editor, `s` / `S` are
fuzzy file / content search, and Neovim carries a VSCode-shaped keymap
(`Ctrl-s` save, `Ctrl-p` quick open, `Ctrl-b` back to yazi, `<leader>` is
space).

## Keys

Every shortcut gets through a stock Ghostty on macOS and a stock Windows
Terminal, on a French layout as well, with no terminal configuration. So the
IDE is driven by `Ctrl`+letter chords, Neovim's `Space` leader and one zellij
prefix. `Alt` is Option on a Mac and types characters there. Windows Terminal
keeps `Alt`+arrows and most `Ctrl+Shift` chords for itself, and `Cmd` never
reaches a terminal app. Shortcuts built on those still exist as extras where
they get through.

| Keys | Where | Does |
|------|-------|------|
| `Ctrl-h/j/k/l` | Neovim, yazi | Move between Neovim splits, then on to the next pane |
| `Ctrl-g` then `h/j/k/l` | anywhere | Move to the pane in that direction (the way out of the shell) |
| `Ctrl-g` then `t` | anywhere | New terminal in the bottom stack |
| `Ctrl-g` then `c` / `n` / `p` | anywhere | New / next / previous zellij tab |
| `Ctrl-g` then `z` / `f` / `x` / `q` | anywhere | Zoom pane / floating panes / close pane / close tab |
| `Ctrl-g` then `r` / `s` / `d` | anywhere | Resize mode / session manager / detach |
| `Ctrl-g` `Ctrl-g` | anywhere | A literal `Ctrl-g` for the app |
| `Ctrl-s` · `Ctrl-p` · `Ctrl-b` | Neovim | Save · quick open · focus yazi |
| `Ctrl-o` / `Ctrl-i` | Neovim | Navigate back / forward |
| `Ctrl-j` / `Ctrl-k` on a selection | Neovim | Move the lines down / up (`V` first for one line) |
| `Space /` | Neovim | Toggle comment |
| `Space T` · `Space tn` / `Space tp` | Neovim | New Neovim terminal · next / previous one |
| `Ctrl-q` | Neovim | Visual block (Windows Terminal pastes on `Ctrl-v`) |

While the prefix is active, the status bar lists its everyday keys. `Alt-h/j/k/l`,
`Alt-t` and `Alt-q` still work where `Alt` exists (Windows Terminal, Linux).

## Options

All under `programs.codingIde`:

| Option | Default | What it is |
|--------|---------|------------|
| `enable` | `false` | Turn the IDE on. Importing the module alone changes nothing. |
| `clipboardProvider` | `"osc52"` | How Neovim and zellij reach the system clipboard: `"wsl"` (WSLg `wl-copy`, falling back to `clip.exe`), `"pbcopy"` (macOS), `"osc52"` (terminal escapes — works headless / over SSH), `"none"` (leave Neovim's autodetection alone). Only `"wsl"` pulls in the Linux-only `wl-clipboard`. |
| `claudeCode.enable` | `true` | Put `claude` on the shell's and Neovim's PATH (claudecode.nvim drives it in-editor). |
| `claudeCode.package` | this flake's `claude-code` input | Which `claude` build to use — set it to `pkgs.claude-code` on a host that already overlays one in. |
| `nixd.nixpkgsExpr` | `import <this flake's nixpkgs> { }` | The nixpkgs instance nixd completes `pkgs.*` against. |
| `nixd.options` | `{ }` | Option sets nixd completes against, as `name -> nix expression`. |

### Wiring nixd at your own config

Out of the box nixd does evaluation, `pkgs.*` completion and go-to-definition.
To also complete *options* — `programs.` in a `home.nix`, `services.` in a
`configuration.nix` — point it at your own flake's outputs. nixd's names matter
here: `nixos` drives `configuration.nix` files, `home-manager` drives
`home.nix` files.

For a NixOS host with Home Manager embedded in it:

```nix
programs.codingIde.nixd = {
  nixpkgsExpr = ''import (builtins.getFlake "${inputs.self}").inputs.nixpkgs { }'';
  options = {
    nixos = ''(builtins.getFlake "${inputs.self}").nixosConfigurations.myhost.options'';
    home-manager = ''(builtins.getFlake "${inputs.self}").nixosConfigurations.myhost.options.home-manager.users.type.getSubOptions [ ]'';
  };
};
```

For a standalone Home Manager host:

```nix
programs.codingIde.nixd.options.home-manager =
  ''(builtins.getFlake "${inputs.self}").homeConfigurations.myhost.options'';
```

`${inputs.self}` is the flake's store path — a pinned snapshot, which is fine:
option *names* come from the modules, not from your values.

## Hack on it

```
nix fmt                    # nixfmt-tree over the tree
nix flake check            # formatting, then the IDE built for a dummy user on this system
```

`nix flake check` is heavy — it builds Neovim with every plugin, LSP and
formatter — but it is the cheapest way to catch an option rename in nixvim or
Home Manager before a host does. The helper scripts are
`writeShellApplication`s, so the same build also shellchecks them.
`lib.mkExampleHome { system = "..."; }` is the same build, and takes extra
`modules` if you want to try an option out.

To test an uncommitted change from a flake that consumes this one:

```
--override-input codide path:/path/to/CodIDE
```

## Layout

| Path | What |
|------|------|
| `flake.nix` | Inputs, `homeModules.default`, `checks`, `formatter`, `lib.mkExampleHome` |
| `modules/coding-ide/default.nix` | The options, the yazi sidebar, the zellij layouts and chrome, the helper scripts, the `coding` / `gitview` / `fif` shell functions |
| `modules/coding-ide/nvim.nix` | The editor: nixvim plugins, LSPs, formatters, linters, keymaps |
| `modules/coding-ide/icons.nix` | The Nerd Font glyphs both of the above use, as codepoints (literal ones get stripped in transit) |

Both module files take this flake's inputs as a static argument (`flakeInputs`,
applied with `lib.modules.importApply`) rather than through a `specialArgs`
named `inputs`, so they compose with any consuming flake whatever it calls its
own arguments.
