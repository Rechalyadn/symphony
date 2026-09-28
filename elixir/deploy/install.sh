#!/usr/bin/env bash
# Builds the symphony_service release and installs it as a systemd user
# service. Safe to rerun: each run installs a new versioned copy and points
# `current` at it, so upgrading is "rerun, then restart", and rolling back is
# pointing `current` at the previous directory.
set -euo pipefail

cd "$(dirname "$0")/.."

share_dir="$HOME/.local/share/symphony"
config_dir="$HOME/.config/symphony"
state_dir="$HOME/.local/state/symphony"
unit_dir="$HOME/.config/systemd/user"

MIX_ENV=prod mix deps.get --only prod >/dev/null
MIX_ENV=prod mix release symphony_service --overwrite >/dev/null

# A build from uncommitted changes is marked, so `current` never claims to be
# a commit it is not.
dirty="$(git diff --quiet HEAD -- . && echo "" || echo "-dirty")"
version="$(date +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)$dirty"
target="$share_dir/releases/$version"

mkdir -p "$share_dir/releases" "$config_dir" "$state_dir" "$unit_dir"
# Copy rather than run from _build: a later rebuild would otherwise replace
# files under the running service.
cp -a _build/prod/rel/symphony_service "$target"
ln -sfn "$target" "$share_dir/current"

if [ ! -e "$config_dir/env" ]; then
  sed "s|/home/REPLACE_ME|$HOME|g" deploy/symphony.env.example > "$config_dir/env"
  chmod 600 "$config_dir/env"
  echo "Created $config_dir/env - fill in LINEAR_API_KEY and SYMPHONY_WORKFLOW."
fi

cp deploy/symphony.service "$unit_dir/symphony.service"
systemctl --user daemon-reload

echo "Installed $version"
echo "  current -> $target"
echo
echo "First time:"
echo "  loginctl enable-linger \"$USER\"     # keep running after you log out"
echo "  systemctl --user enable --now symphony"
echo "After an upgrade:"
echo "  systemctl --user restart symphony"
echo "Logs:"
echo "  tail -f $state_dir/log/symphony.log.1    journalctl --user -u symphony"
