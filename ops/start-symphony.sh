#!/bin/bash
# Start a Symphony instance for a given workflow file.
# Usage: start-symphony.sh <workflow-file> [dashboard-port]
set -euo pipefail

WORKFLOW="${1:?usage: start-symphony.sh <workflow-file> [dashboard-port]}"
PORT="${2:-}"

SYMPHONY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SYMPHONY_ENV_FILE:-$HOME/finsider-platform/agentic-development/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WORKFLOW_ABS="$(cd "$(dirname "$WORKFLOW")" && pwd)/$(basename "$WORKFLOW")"
LOGS_ROOT="$SYMPHONY_ROOT/logs/$(basename "$WORKFLOW" .md)"
mkdir -p "$LOGS_ROOT"

cd "$SYMPHONY_ROOT/upstream/elixir"

ARGS=("$WORKFLOW_ABS" --logs-root "$LOGS_ROOT" --i-understand-that-this-will-be-running-without-the-usual-guardrails)
if [[ -n "$PORT" ]]; then
  ARGS+=(--port "$PORT")
fi

exec mise exec -- ./bin/symphony "${ARGS[@]}"
