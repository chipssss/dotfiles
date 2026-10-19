{ user, ... }:

{
  # Determinate already manages the Nix daemon, so nix-darwin shouldn't.
  nix.enable = false;

  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = "aarch64-darwin"; # use x86_64-darwin for Intel CPU

  system.primaryUser = user;
  users.users.${user} = {
    home = "/Users/${user}";
  };
  system.stateVersion = 6;
  system.defaults = {
    NSGlobalDomain = {
      AppleInterfaceStyle = "Dark";
      KeyRepeat = 2;          # fast key repeat
      InitialKeyRepeat = 15;  # short delay before repeat
      _HIHideMenuBar = true;  # auto-hide the menu bar
      AppleShowAllExtensions = true;
      "com.apple.keyboard.fnState" = true;  # F1-F12 act as standard function keys
    };
    dock.autohide = true;
    dock.tilesize = 64;                    # larger Dock icons (default 48)
    dock.wvous-br-corner = 5;              # bottom-right hot corner: start screen saver
    finder.FXPreferredViewStyle = "Nlsv";  # list view by default
    finder.CreateDesktop = false;          # clean desktop
    finder.AppleShowAllFiles = true;       # show hidden files in Finder
    finder.FXRemoveOldTrashItems = true;   # empty Trash items after 30 days
    trackpad.Clicking = true;              # tap to click
    trackpad.TrackpadThreeFingerDrag = true;  # three-finger drag
  };

  # Homebrew via nix-darwin is intentionally OFF on this machine.
  # Reason: onActivation.cleanup = "zap" would uninstall any brew package not
  # listed below; Lin already has ~190 formulas managed outside this list.
  # Personal CLI/cask recovery uses Brewfile at the repo root:
  #   brew bundle --file=~/.dotfiles/Brewfile
  # Re-enable only after the brews/casks arrays mirror what you want to keep.
  nix-homebrew = {
    enable = false;
    inherit user;
  };
  homebrew = {
    enable = false;
    onActivation.cleanup = "zap";  # remove anything not listed here
    onActivation.autoUpdate = true;
    onActivation.extraFlags = [ "--force" ];
    brews = [
      "herdr"
    ];
    casks = [
      "wezterm"
      "claude-code"
    ];
  };
}
