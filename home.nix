{ config, pkgs, lib, user, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
  zshMarkerBegin = "# >>> dotfiles incremental additions >>>";
  zshMarkerEnd = "# <<< dotfiles incremental additions <<<";
in

{
  home.username = user;
  home.homeDirectory = "/Users/${user}";
  home.stateVersion = "24.11";
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep # fast search
    fd # fast find
    fzf # fuzzy finder
    jq # json on the command line
    lazygit
    neovim
    typescript-language-server # TypeScript navigation for Neovim's built-in LSP
    starship
    zsh-autosuggestions
    zsh-syntax-highlighting
    # the font everything renders in
    nerd-fonts.hack
  ];
  fonts.fontconfig.enable = true;
  home.sessionVariables.EDITOR = "nvim";

  # Existing ~/.zshrc and ~/.zshenv stay user-owned. Repository additions live
  # in home/.zshrc.additions and home/.zshenv.additions; activation below
  # ensures those files are sourced (idempotent markers).

  # Edit-in-place: the real file stays in my repo, ~/.config just points at it.
  home.file.".config/wezterm".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
  home.file.".config/ghostty".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/ghostty";
  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
  home.file.".config/herdr/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr/config.toml";
  home.file.".config/starship.toml".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/starship.toml";

  # Keep Pi's credential and runtime state local by linking only authored files and directories.
  home.file.".pi/agent/themes".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/themes";
  home.file.".pi/agent/extensions".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/extensions";
  home.file.".pi/agent/models.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/models.json";
  # Pi rewrites settings (device ID, changelog, proxy, preferences). Keep its
  # writable file local; activation reapplies only the repository-authored keys.
  # Migrate before cleanOldGen (inside linkGeneration) unlinks the old file.
  home.activation.syncPiSettings = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
    PATH="${pkgs.jq}/bin:$PATH" /bin/sh ${./home/pi-settings-sync.sh} \
      ${./home/.pi/agent/settings.json} "$HOME/.pi/agent/settings.json"
  '';

  # Pi worker dispatch (home/dispatch/README.md). The helpers stay in the repo next to these
  # entry points; only machine-wide safety policy belongs in the local config.
  home.file.".local/bin/dispatch".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/dispatch/dispatch";
  home.file.".claude/bin/pi-worker".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/dispatch/pi-worker";

  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".codex/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".config/opencode/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";

  home.activation.ensureDotfilesZshSnippets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ensure_source() {
      local target="$1"
      local addition="$2"
      mkdir -p "$(dirname "$target")"
      touch "$target"
      if ! grep -Fqx "${zshMarkerBegin}" "$target"; then
        {
          echo ""
          echo "${zshMarkerBegin}"
          echo "source \"$addition\""
          echo "${zshMarkerEnd}"
        } >> "$target"
      fi
    }
    ensure_source "$HOME/.zshenv" "${dotfiles}/home/.zshenv.additions"
    ensure_source "$HOME/.zshrc" "${dotfiles}/home/.zshrc.additions"
  '';
}
