#!/bin/sh
# Merge authored defaults into mutable, machine-local Pi settings. Never write
# through the former Home Manager/repository symlink, or discard unknown keys.
set -eu
[ "$#" = 2 ] || { echo 'usage: pi-settings-sync DEFAULTS SETTINGS' >&2; exit 64; }
defaults=$1
settings=$2
mkdir -p "$(dirname "$settings")"
umask 077
tmp=$(mktemp "${settings}.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
if [ -e "$settings" ]; then
  jq -e --slurpfile defaults "$defaults" '
    if type == "object" and ($defaults[0] | type) == "object"
    then . * $defaults[0] else error("settings must be objects") end
  ' "$settings" > "$tmp"
elif [ -L "$settings" ]; then
  echo 'pi-settings-sync: broken settings symlink; repair it before activation' >&2
  exit 1
else
  jq -e 'if type == "object" then . else error("defaults must be an object") end' "$defaults" > "$tmp"
fi
# Replacing the link itself is intentional, including the first migration.
mv -f "$tmp" "$settings"
