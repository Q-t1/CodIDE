# The `coding` IDE: a two-pane zellij workspace — yazi as a file sidebar on the
# left, Neovim (see ./nvim.nix) on the right — bridged by a per-tab nvim
# socket so yazi/fif open files as native nvim tabs.
#
# This is a Home Manager module, exported as `homeModules.default` by this
# flake. It takes the flake's own inputs as a static argument (`flakeInputs`,
# applied with `lib.modules.importApply`) rather than through a `specialArgs`
# named `inputs`, so it composes with any consuming flake regardless of what
# that flake calls its own inputs. A host turns it on with
# `programs.codingIde.enable` and tunes it with the other options there
# (clipboard, nixd, claude CLI).
flakeInputs:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.codingIde;

  # Catppuccin Mocha (mauve accent) for yazi — matches the Neovim IDE's
  # colorscheme (nvim.nix) and the zellij chrome, so editor, picker and
  # multiplexer share one palette. Catppuccin ships a plain per-accent theme.toml
  # (not the yazi flavor-package format), so read it straight into
  # programs.yazi.theme; swap the filename for another accent under themes/mocha/.
  catppuccinYaziTheme = lib.importTOML "${flakeInputs.catppuccin-yazi}/themes/mocha/catppuccin-mocha-mauve.toml";

  nvim = lib.getExe config.programs.nixvim.build.package;
  zellij = lib.getExe config.programs.zellij.package;

  # The helper scripts below are writeShellApplications: shellchecked at build
  # time and run under `set -euo pipefail`. The ones that end up exec-ing an
  # interactive Neovim call their tools by absolute path instead of through
  # runtimeInputs, which would otherwise leak onto the PATH of every shell
  # opened from inside that Neovim.

  # Prints the zellij tab id of the calling pane, or nothing outside zellij.
  # `list-panes --tab` is scoped to the calling pane's own tab, so filtering it
  # down to this pane's id resolves "my tab" rather than "the focused tab" —
  # switching tabs while a script runs can't make it act on the wrong one.
  zellijTabId = pkgs.writeShellApplication {
    name = "coding-tab-id";
    runtimeInputs = [
      config.programs.zellij.package
      pkgs.jq
    ];
    text = ''
      # shellcheck disable=SC2016 # $pane is a jq variable
      zellij action list-panes --tab --json 2>/dev/null |
        jq -r --argjson pane "''${ZELLIJ_PANE_ID:-null}" \
          '.[] | select((.is_plugin | not) and .id == $pane) | .tab_id' 2>/dev/null ||
        true
    '';
  };

  # Prints the socket path for *this tab's* Neovim. A session can hold more
  # than one "Coding" tab (the `coding` function's `-n "$ZELLIJ"` branch adds
  # one instead of starting a new session), each running its own yazi +
  # Neovim pair — so the socket has to be scoped per tab, not just per
  # session, or the second tab's Neovim fails to bind the first one's socket
  # (EADDRINUSE, pane exits immediately) while that tab's yazi keeps
  # "succeeding" by silently opening files into the first tab's Neovim.
  tabScopedSock = pkgs.writeShellApplication {
    name = "coding-tab-socket";
    text = ''
      tab_id=$(${lib.getExe zellijTabId})
      printf '/tmp/nvim-%s-%s.sock' "''${ZELLIJ_SESSION_NAME:-}" "''${tab_id:-0}"
    '';
  };

  # Starts Neovim listening on a tab-scoped socket so yazi, fif, and any
  # other pane in the same zellij tab can open files into the same instance
  # via --remote, giving a barbar buffer tabline instead of zellij stacked
  # panes.
  #
  # It also names its own zellij tab "Coding | <folder>": a layout can't
  # interpolate the directory, so a fresh `coding` session would otherwise keep
  # the static layout name.
  codingNvim = pkgs.writeShellApplication {
    name = "coding-nvim";
    text = ''
      sock=$(${lib.getExe tabScopedSock})
      tab_id=$(${lib.getExe zellijTabId})
      if [ -n "$tab_id" ]; then
        ${zellij} action rename-tab --tab-id "$tab_id" "Coding | ''${PWD##*/}" || true
      fi
      exec ${nvim} --listen "$sock" "$@"
    '';
  };

  # `coding-open FILE [LINE]` opens FILE (at LINE) in this tab's Neovim over
  # its socket, and fails without doing anything when there is no such Neovim,
  # so each caller picks its own fallback. CodingIdeFocusEditor (nvim.nix)
  # first moves Neovim off any terminal or panel window, so --remote's `:drop`
  # opens the file as a buffer (a barbar tab) in an editor window.
  openInTabNvim = pkgs.writeShellApplication {
    name = "coding-open";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      file=$(realpath -- "''${1:?usage: coding-open FILE [LINE]}")
      line=''${2:-}
      sock=$(${lib.getExe tabScopedSock})
      [ -S "$sock" ] || exit 1
      ${nvim} --server "$sock" --remote-expr "v:lua.CodingIdeFocusEditor()" >/dev/null
      ${nvim} --server "$sock" --remote "$file"
      if [ -n "$line" ]; then
        ${nvim} --server "$sock" --remote-send "<Esc>:$line<CR>"
      fi
    '';
  };

  # yazi's `edit` opener: opens the picked file in this tab's Neovim, then
  # focuses it — yazi is the left pane, so move-focus Right always lands on
  # the editor column.
  openFileInNvim = pkgs.writeShellApplication {
    name = "open-file-in-nvim";
    text = ''
      ${lib.getExe openInTabNvim} "$1"
      ${zellij} action move-focus Right
    '';
  };

  # yazi's built-in `S`/`s` search only ever surfaces files (never a matched
  # line) and its results don't route through the `edit` opener reliably. These
  # replace both with fzf pickers — the same flow as the `fif` shell function —
  # that open the pick in the tab's Neovim over the socket and (for content
  # search) jump to the matched line, then focus the editor pane on the right.
  #
  # Launched from yazi via `shell "<script>" --block`, so fzf takes over the
  # yazi (left) pane while running; on pick we hop focus Right to the editor.
  yaziRgSearch = pkgs.writeShellApplication {
    name = "yazi-rg-search";
    runtimeInputs = with pkgs; [
      ripgrep
      fzf
      bat
      coreutils
      gnused
    ];
    text = ''
      RG_PREFIX="rg --column --line-number --no-heading --color=always --smart-case"
      result=$(
        : | fzf --ansi --disabled \
            --bind "start:reload:$RG_PREFIX {q} || true" \
            --bind "change:reload:sleep 0.1; $RG_PREFIX {q} || true" \
            --delimiter ':' \
            --preview 'bat --color=always --highlight-line {2} -- {1}' \
            --preview-window 'right:60%,+{2}+3/3,border-left'
      ) || exit 0
      clean=$(printf '%s' "$result" | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g')
      file=''${clean%%:*}
      rest=''${clean#*:}
      line=''${rest%%:*}
      [ -n "$file" ] || exit 0
      if ${lib.getExe openInTabNvim} "$file" "$line"; then
        ${zellij} action move-focus Right
      else
        ${nvim} "$(realpath -- "$file")" "+$line"
      fi
    '';
  };

  yaziFdSearch = pkgs.writeShellApplication {
    name = "yazi-fd-search";
    runtimeInputs = with pkgs; [
      fd
      fzf
      bat
      coreutils
    ];
    # No pipefail: fd is usually still writing when fzf exits on a pick, and
    # its SIGPIPE would turn every pick into a failure.
    bashOptions = [
      "errexit"
      "nounset"
    ];
    text = ''
      file=$(
        fd --type f --hidden --follow --exclude .git |
          fzf --ansi \
              --preview 'bat --color=always -- {}' \
              --preview-window 'right:60%,border-left'
      ) || exit 0
      [ -n "$file" ] || exit 0
      if ${lib.getExe openInTabNvim} "$file"; then
        ${zellij} action move-focus Right
      else
        ${nvim} "$(realpath -- "$file")"
      fi
    '';
  };

  # Shared zellij chrome for both IDE layouts (coding + git): the built-in
  # tab-bar on top, and a zjstatus strip on the bottom showing the session
  # name (left) and the git branch + clock (right). The branch command appends
  # a " *" when the tree is dirty (tracked changes or untracked files), so the
  # status bar doubles as a "you have uncommitted work" indicator. Factored out
  # here so the two layouts stay identical instead of drifting.
  zellijChrome = ''
    pane size=1 borderless=true {
        plugin location="zellij:tab-bar"
    }
    children
    pane size=1 borderless=true {
        plugin location="file:${pkgs.zellijPlugins.zjstatus}" {
            format_left   "#[fg=#cba6f7,bold] {session} "
            format_center ""
            format_right  "{command_git_branch}{datetime}"

            command_git_branch {
                command  "bash"
                args     "-c" "b=$(git -C #{cwd} branch --show-current 2>/dev/null) || exit 0; [ -z \"$b\" ] && exit 0; [ -n \"$(git -C #{cwd} status --porcelain 2>/dev/null)\" ] && b=\"$b *\"; printf %s \"$b\""
                format   "#[fg=#a6e3a1]  {stdout} "
                interval "5"
            }

            datetime {
                format   "#[fg=#6c7086,italic] %H:%M "
                timezone "Europe/Paris"
            }
        }
    }
  '';
in
{
  imports = [ (lib.modules.importApply ./nvim.nix flakeInputs) ];

  options.programs.codingIde = {
    enable = lib.mkEnableOption "CodIDE, the yazi + zellij + Neovim terminal IDE";

    clipboardProvider = lib.mkOption {
      type = lib.types.enum [
        "wsl"
        "pbcopy"
        "osc52"
        "none"
      ];
      default = "osc52";
      example = "wsl";
      description = ''
        How the IDE's Neovim and zellij reach the system clipboard.
        "wsl" bridges to Windows via wl-copy with a clip.exe/PowerShell fallback
        (WSLg); "pbcopy" uses macOS' native pbcopy/pbpaste; "osc52" uses terminal
        OSC 52 escapes, which work headless / over SSH (e.g. a remote container);
        "none" leaves Neovim's autodetection be.
      '';
    };

    claudeCode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Put the `claude` CLI on the interactive shell's PATH and on Neovim's
          (claudecode.nvim drives it as an in-editor agent). Turn this off on a
          host that gets `claude` from somewhere else, or not at all.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = flakeInputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default;
        defaultText = lib.literalExpression "the claude-code flake input's package for this system";
        description = ''
          Which `claude` build to use. Defaults to this flake's `claude-code`
          input (github:sadjow/claude-code-nix — hourly upstream releases, and
          its own cachix), taken straight from that flake rather than through an
          overlay so a consumer needs neither the overlay nor `allowUnfree`.
          Set it to `pkgs.claude-code` on a host that already overlays one in.
        '';
      };
    };

    nixd = {
      nixpkgsExpr = lib.mkOption {
        type = lib.types.str;
        default = "import ${flakeInputs.nixpkgs} { }";
        defaultText = lib.literalExpression "\"import <this flake's pinned nixpkgs> { }\"";
        description = ''
          Nix expression nixd evaluates to get a nixpkgs instance, backing
          completion and hover for `pkgs.*`.
        '';
      };

      options = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = lib.literalExpression ''
          {
            nixos = "(builtins.getFlake \"/etc/nixos\").nixosConfigurations.myhost.options";
          }
        '';
        description = ''
          Option sets nixd completes against, as `name -> nix expression`. The
          names are nixd's own conventions: `nixos` drives configuration.nix
          files and `home-manager` drives home.nix files, so typing `programs.`
          in one completes against the modules actually in scope.

          Left empty (the default) nixd still does everything that does not need
          a host: evaluation, `pkgs.*` completion, go-to-definition. Point this
          at your own flake's outputs to get option completion too — see the
          README.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # IDE tooling the launcher and shell functions call interactively. The
    # packaged helper scripts above carry their own deps; these are the ones
    # the *user's* shell invokes, so they go on PATH.
    home.packages =
      (with pkgs; [
        fd # yazi's file finder + `s` name search (the `coding` left pane)
        ripgrep # yazi's content search and the `fif` function
        fzf # the picker behind `fif` and yazi's s/S searches
        bat # previews in those pickers
        lazygit # full git UI; also the `git` zellij layout / gitview
      ])
      # `claude` on the interactive shell's PATH. nvim.nix puts it on Neovim's
      # PATH too, but that only reaches the wrapped Neovim (claudecode.nvim),
      # not the shell.
      ++ lib.optional cfg.claudeCode.enable cfg.claudeCode.package;

    # Free Ctrl-S / Ctrl-Q from XON/XOFF flow control so the save keybind never
    # freezes an interactive terminal, and provide the `coding` launcher.
    programs.zsh.initContent = ''
      [[ $- == *i* ]] && stty -ixon 2>/dev/null

      # `coding [target]` opens the IDE inside a zellij "coding" layout (yazi file
      # pane on the left, Neovim + a shell strip on the right), rooted at the target
      # so yazi, the LSP and telescope all use that project. A file target skips the
      # layout and just edits the file (keeps single-file / $EDITOR-style use fast).
      # Inside an existing zellij session it adds a tab instead of nesting.
      coding() {
        local target="''${1:-.}"
        if [[ -f "$target" ]]; then
          nvim -- "$target"
          return
        fi
        local dir="''${target:A}" # zsh: resolve to an absolute path
        local tab_name="Coding | ''${dir:t}"
        if [[ -n "$ZELLIJ" ]]; then
          zellij action new-tab --layout coding --cwd "$dir" --name "$tab_name"
        else
          local session_name="coding-''${dir:t}"
          local _sessions
          _sessions=$(zellij list-sessions 2>/dev/null)
          # A live session has the name but no EXITED marker; an exited one shows
          # "(EXITED - attach to resurrect)" — attaching resurrects it as a bare
          # shell without the layout, which is the "run twice" bug. Delete the
          # zombie and start fresh instead.
          local _live
          _live=$(echo "$_sessions" | grep -F "$session_name" | grep -vi 'EXITED')
          if [[ -n "$_live" ]]; then
            ( builtin cd -- "$dir" && zellij attach "$session_name" )
          else
            zellij delete-session "$session_name" 2>/dev/null
            # Use -n/--new-session-with-layout, NOT --layout: with -s present,
            # `--layout coding` means "add a tab to session coding-<dir>", which
            # doesn't exist yet, so zellij errors "Session not found". -n always
            # starts a new session, so it composes with -s.
            ( builtin cd -- "$dir" && zellij -s "$session_name" -n coding )
          fi
        fi
      }

      # `gitview [dir]` opens a dedicated git tab (full-screen lazygit). Inside
      # an existing zellij session it adds a tab; outside it starts a new session.
      gitview() {
        local target="''${1:-.}"
        local dir="''${target:A}"
        local tab_name="git: ''${dir:t}"
        if [[ -n "$ZELLIJ" ]]; then
          zellij action new-tab --layout git --cwd "$dir" --name "$tab_name"
        else
          ( builtin cd -- "$dir" && zellij -n git )
        fi
      }

      # `fif <pattern> [rg-args]` — interactive ripgrep | fzf content search with
      # bat preview. Selecting a match opens the file at the matched line in the
      # tab's Neovim via its socket, then moves focus to the editor pane.
      fif() {
        if [[ $# -eq 0 ]]; then
          print -u2 "usage: fif <pattern> [rg-args...]"; return 1
        fi
        local result
        result=$(
          rg --color=always --line-number --no-heading --smart-case -- "$@" |
            fzf --ansi \
                --delimiter ':' \
                --preview 'bat --color=always --highlight-line {2} -- {1}' \
                --preview-window 'right:60%,+{2}+3/3,border-left'
        ) || return
        local clean file rest line
        clean=$(printf '%s' "$result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g')
        file="''${clean%%:*}"
        rest="''${clean#*:}"
        line="''${rest%%:*}"
        # fif runs in the terminal strip under the editor, hence Up.
        if ${lib.getExe openInTabNvim} "$file" "$line"; then
          ${zellij} action move-focus Up
        else
          nvim "$(realpath -- "$file")" "+$line"
        fi
      }
    '';

    # yazi is the IDE's file manager, running as the persistent left pane of the
    # `coding` zellij layout (below). Picking a file opens it in the Neovim pane on
    # the right over a server socket (see the `edit` opener and the layout).
    programs.yazi = {
      enable = true;

      # No shell wrapper: yazi is the IDE's file pane, not a `y`-to-cd shell
      # command, so the zsh integration would only add noise.
      enableZshIntegration = false;

      settings = {
        mgr = {
          # Collapse yazi to a single column (parent + preview off). In a narrow
          # sidebar this reads like a file tree, and the content preview is
          # redundant anyway — the file's contents show in the Neovim pane.
          ratio = [
            0
            1
            0
          ];
          show_hidden = true; # dotfiles matter in a Nix repo (.rtk, .git-ignored…)
          sort_dir_first = true;
        };

        # Open (Enter) sends the picked file to the tab's Neovim via its
        # socket (--remote), which opens it as a buffer / barbar tab. block=false
        # keeps yazi visible as the sidebar. realpath is required: yazi may pass
        # a path relative to its cwd, but the socket command resolves against
        # nvim's cwd → wrong file from a subdir without it.
        #
        # `%s` (not `$1`) is yazi's placeholder for the target file: yazi's
        # `run` string is its own template language, substituted before the
        # shell ever sees it — `$1` is never populated, since yazi doesn't
        # invoke openers with the file as a positional shell argument. With
        # `$1` here, every open silently no-ops (empty path → failed realpath
        # → nvim --remote with no file), with no error visible anywhere.
        opener.edit = [
          {
            run = "${lib.getExe openFileInNvim} %s";
            desc = "Open in editor";
            block = false;
          }
        ];
        open.prepend_rules = [
          {
            url = "*";
            use = "edit";
          }
        ];
      };

      # Mouse: a left click opens a file (in the Neovim pane) or enters a folder,
      # like VSCode's explorer; a right click anywhere in the list — empty
      # folders included — goes up to the parent folder, since the single-column
      # sidebar (mgr.ratio) has no parent column to click in. Overrides the
      # preset, where a left click only moves the cursor and a right click opens.
      initLua = ''
        function Entity:click(event, up)
          if up or not event.is_left then
            return
          end
          ya.emit("reveal", { self._file.url })
          ya.emit(self._file.cha.is_dir and "enter" or "open", {})
        end

        local current_click = Current.click
        function Current:click(event, up)
          if event.is_right then
            if not up then
              ya.emit("leave", {})
            end
            return
          end
          current_click(self, event, up)
        end
      '';

      # Replace yazi's built-in fd/rg search (which can't open at a matched line
      # and doesn't route content-search results through the `edit` opener) with
      # fzf pickers that open the pick in the tab's Neovim — the rg one jumps
      # to the matched line. prepend_keymap wins over the defaults, so `s`/`S`
      # keep their familiar meaning. Run with --block so fzf owns the pane while
      # picking (see yaziRgSearch / yaziFdSearch in the let block above).
      keymap.mgr.prepend_keymap = [
        {
          on = "S";
          run = ''shell "${lib.getExe yaziRgSearch}" --block'';
          desc = "Search file contents (rg) → open at match";
        }
        {
          on = "s";
          run = ''shell "${lib.getExe yaziFdSearch}" --block'';
          desc = "Search files by name (fd) → open";
        }
      ];

      # Catppuccin Mocha (mauve) — see the let binding at the top of this file.
      theme = catppuccinYaziTheme;
    };

    programs.zellij = {
      enable = true;

      settings = {
        # Catppuccin Mocha — a zellij built-in theme, matched to the Neovim IDE's
        # colorscheme (nvim.nix) so the editor and the surrounding zellij chrome
        # share one palette.
        theme = "catppuccin-mocha";

        # Hovering a pane focuses it, and a click on a pane that isn't focused yet
        # also reaches the app in it, so one click in yazi or Neovim acts right
        # away instead of first spending itself on focus. Stacked panes still
        # need a click to expand.
        # Mouse drag-select in a (non-Neovim) pane copies straight to the system
        # clipboard. On WSL that routes through clip.exe and on macOS through
        # pbcopy (copy_command below); elsewhere zellij falls back to OSC 52.
        # Neovim panes keep their own mouse handling (mouse=a), since Neovim
        # requests mouse tracking and zellij forwards events to it.
        mouse_mode = true;
        focus_follows_mouse = true;
        mouse_click_through = true;
        copy_on_select = true;
      }
      // lib.optionalAttrs (cfg.clipboardProvider == "wsl") {
        # WSL: bypass OSC 52 and hand the selection to Windows directly —
        # reliable regardless of WSLg's Wayland state.
        copy_command = "clip.exe";
      }
      // lib.optionalAttrs (cfg.clipboardProvider == "pbcopy") {
        # macOS: the real system clipboard, no terminal round-trip needed.
        copy_command = "pbcopy";
      };

      # Full-screen lazygit tab, launched by `gitview`. Alt-t still adds a
      # terminal below if needed; lazygit's own bottom panel handles most shell
      # needs (press `e` to open the embedded shell in a lazygit split).
      layouts.git = ''
        layout {
            default_tab_template {
                ${zellijChrome}
            }
            tab name="git" focus=true {
                pane name="lazygit" focus=true {
                    command "${lib.getExe pkgs.lazygit}"
                }
            }
        }
      '';

      # IDE workspace launched by the `coding` shell function:
      #
      #   ┌ files ┐┌──────── editor (nvim) ────────┐
      #   │ yazi  ││ [file1] │ [file2] │ [file3] … │  ← barbar tabline (top)
      #   │       │├────────── terminal ───────────┤
      #   └───────┘└───────────────────────────────┘
      #
      # Neovim runs with --listen on a tab-scoped socket (coding-nvim wrapper).
      # Enter on a file in yazi calls open-file-in-nvim which does --remote,
      # opening the file as a buffer. The barbar tabline at the top of the
      # editor pane is the open-files list. Alt-t adds a new zellij terminal tab.
      layouts.coding = ''
        layout {
            default_tab_template {
                ${zellijChrome}
            }
            // Placeholder: coding-nvim renames it to "Coding | <folder>".
            tab name="Coding" focus=true {
                pane split_direction="vertical" {
                    pane size="24%" name="files" focus=true {
                        command "${lib.getExe config.programs.yazi.finalPackage}"
                    }
                    pane split_direction="horizontal" {
                        pane size="80%" name="editor" {
                            command "${lib.getExe codingNvim}"
                        }
                        pane stacked=true {
                            pane name="terminal"
                        }
                    }
                }
            }
        }
      '';

      # zellij is modal and, in its Normal mode, intercepts a handful of Ctrl
      # chords before the running app sees them — several of which the nixvim IDE
      # (nvim.nix) relies on, most importantly Ctrl-s (save). Free those in Normal
      # mode so they reach Neovim:
      #   Ctrl-s save · Ctrl-p quick-open / blink prev · Ctrl-n blink next ·
      #   Ctrl-h seamless split/pane nav across Neovim and zellij (see nvim.nix)
      # zellij keeps everything else, driven from its Alt bindings (Alt-n new
      # pane, Alt-h/j/k/l move focus, Alt-+/- resize, Alt-f float, Alt-[/] cycle
      # layouts) plus Ctrl-g lock, Ctrl-t tab, Ctrl-o session, Ctrl-q quit.
      #
      # Alt-t opens a new plain terminal tab (a zellij tab, not a stacked pane).
      extraConfig = ''
        keybinds {
            normal {
                unbind "Ctrl s"
                unbind "Ctrl p"
                unbind "Ctrl n"
                unbind "Ctrl h"

                // Add a new pane to the terminal stack (shows as a horizontal tab strip).
                // Focus must land on the stack first; NewPane without stacked=true
                // adds to the focused stack rather than creating an independent pane.
                bind "Alt t" { MoveFocus "Right"; MoveFocus "Down"; NewPane; }
                bind "Alt q" { CloseTab; }
            }
        }
      '';
    };
  };
}
