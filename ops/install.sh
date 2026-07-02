#!/bin/bash
# One-shot installer: toolchain, build, tests, and launchd services.
set -euo pipefail

REPO="$HOME/Projects/symphony"
ENV_FILE="${SYMPHONY_ENV_FILE:-$HOME/finsider-platform/agentic-development/.env}"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "== Checking prerequisites =="
command -v brew >/dev/null || { echo "Homebrew required"; exit 1; }
command -v mise >/dev/null || brew install mise
command -v codex >/dev/null || { echo "Codex CLI required: brew install codex"; exit 1; }
codex login status || { echo "Run: codex login (ChatGPT/Codex subscription or API key)"; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE (needs JIRA_EMAIL, JIRA_API_TOKEN; optional SLACK_WEBHOOK_URL, GITHUB_TOKEN)"
  exit 1
fi

echo "== Building Symphony (Elixir reference implementation) =="
cd "$REPO/upstream/elixir"
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- mix test

echo "== Installing launchd services =="
mkdir -p "$REPO/logs" "$HOME/finsider-platform/symphony-workspaces/mitch-fe" "$HOME/finsider-platform/symphony-workspaces/mitch-be"
for plist in com.finsider.symphony.mitch-fe com.finsider.symphony.mitch-be com.finsider.symphony.update; do
  launchctl bootout "gui/$(id -u)/$plist" 2>/dev/null || true
  cp "$REPO/ops/launchd/$plist.plist" "$HOME/Library/LaunchAgents/"
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$plist.plist"
done

echo "== Done =="
launchctl list | grep com.finsider.symphony || true
echo "Dashboards: http://127.0.0.1:4310 (mitch-fe), http://127.0.0.1:4311 (mitch-be)"
