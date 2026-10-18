# Editor configs (personal)

Synced from Lin's MacBook personal profile. **Not** auto-linked by home-manager
(so Mini / fresh machines keep their live Cursor state until you opt in).

## Restore after wipe

```sh
# Cursor
mkdir -p "$HOME/Library/Application Support/Cursor/User"
cp ~/.dotfiles/home/editor/cursor/settings.json \
   "$HOME/Library/Application Support/Cursor/User/settings.json"
cp ~/.dotfiles/home/editor/cursor/keybindings.json \
   "$HOME/Library/Application Support/Cursor/User/keybindings.json"
while read -r e; do
  [[ "$e" =~ ^#|^$ ]] && continue
  cursor --install-extension "$e"
done < ~/.dotfiles/home/editor/cursor/extensions.txt

# VS Code (optional)
mkdir -p "$HOME/Library/Application Support/Code/User"
cp ~/.dotfiles/home/editor/vscode/settings.json \
   "$HOME/Library/Application Support/Code/User/settings.json"
while read -r e; do
  [[ "$e" =~ ^#|^$ ]] && continue
  code --install-extension "$e"
done < ~/.dotfiles/home/editor/vscode/extensions.txt
```

Excluded on purpose: `byted-*`, `byted-sec.bytesec-vscode`, and other company-forced extensions.
