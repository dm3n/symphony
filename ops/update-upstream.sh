#!/bin/bash
# Pull the latest openai/symphony into the upstream/ subtree, rebuild, test,
# push, and restart the running Symphony services. Rolls back on failure.
set -euo pipefail

REPO="$HOME/Projects/symphony"
UPSTREAM_URL="https://github.com/openai/symphony"
ENV_FILE="${SYMPHONY_ENV_FILE:-$HOME/finsider-platform/agentic-development/.env}"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

notify() {
  echo "$1"
  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    curl -s -X POST -H 'Content-Type: application/json' \
      -d "{\"text\":\"$1\"}" "$SLACK_WEBHOOK_URL" >/dev/null || true
  fi
}

cd "$REPO"

if [[ -n "$(git status --porcelain)" ]]; then
  notify "Symphony upstream update skipped: working tree at $REPO is dirty."
  exit 1
fi

BEFORE="$(git rev-parse HEAD)"

if ! git subtree pull --prefix upstream "$UPSTREAM_URL" main --squash \
  -m "Update upstream openai/symphony"; then
  git merge --abort 2>/dev/null || true
  git reset --hard "$BEFORE"
  notify "Symphony upstream update FAILED: merge conflict with openai/symphony. Manual merge needed in $REPO."
  exit 1
fi

AFTER="$(git rev-parse HEAD)"
if [[ "$BEFORE" == "$AFTER" ]]; then
  echo "Symphony upstream already up to date."
  exit 0
fi

cd "$REPO/upstream/elixir"
if mise exec -- mix setup && mise exec -- mix build && mise exec -- mix test; then
  cd "$REPO"
  git push origin main || notify "Symphony updated locally but push to origin failed."
  for svc in com.finsider.symphony.mitch-fe com.finsider.symphony.mitch-be; do
    launchctl kickstart -k "gui/$(id -u)/$svc" 2>/dev/null || true
  done
  notify "Symphony updated from openai/symphony upstream, tests green, services restarted."
else
  cd "$REPO"
  git reset --hard "$BEFORE"
  notify "Symphony upstream update FAILED build/tests — rolled back to $BEFORE."
  exit 1
fi
