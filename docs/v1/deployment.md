# Symphony — Deployment & Operations

Symphony runs in two topologies: a **local macOS** deployment for development and a **always-on GCP VM** for production. Both run the same orchestrator; only the supervisor differs.

---

## Local — macOS LaunchAgent

Installed as a user LaunchAgent so it starts at login and restarts on crash:

- `RunAtLoad: true` — starts when the user logs in.
- `KeepAlive: true` — relaunched automatically if it exits.
- Standard out/err redirected to `logs/launchd.out.log` / `logs/launchd.err.log`.
- The launcher sources `.env`, pins the required Node version, and execs the orchestrator with its config and log paths.

Lifecycle helpers exist to install, disable (for migration to the VM), and fully uninstall the LaunchAgent.

```
~/Library/LaunchAgents/<label>.plist   → launchd supervises the daemon
scripts/start-*.sh                      → sources .env, pins Node, runs orchestrator
```

## Production — GCP Compute Engine + systemd

A one-shot deploy script provisions an always-on VM:

1. **Provision** an `e2-standard-4` instance (Ubuntu 24.04 LTS), reusing it if present.
2. **Upload** the orchestrator source (excluding `.env`, `workspaces/`, `logs/`, `node_modules/`).
3. **Bootstrap** the box: `git`, `jq`, `python3`, Node, the `gh` CLI, `ffmpeg`, `xvfb` + Playwright dependencies, the coding-agent CLI, and a dedicated service user.
4. **Install a systemd unit** running as the service user with `Restart=always` and a short `RestartSec`.
5. **Authenticate** `gh` with the provided token; verify identity.
6. **Enable + start** the service and report status.

Secrets land in `/opt/<app>/.env` with `0600` permissions and are sourced at startup. Logs go to the journal:

```
sudo systemctl status <service>
sudo journalctl -u <service> -f
```

## Environment checks (preflight)

`--check` validates the environment without mutating anything:

- `JIRA_EMAIL` and `JIRA_API_TOKEN` present
- `git`, `gh`, the coding-agent CLI, and `node` on `PATH`
- Node at the pinned major version (native backend deps require it)
- every configured repo remote reachable
- `gh` authenticated as the expected account
- Slack webhook **or** bot token + channel configured (if Slack is enabled)

`--dry-run` prints the actions it *would* take for the current Jira state without writing to Jira or disk — the safe way to inspect behavior. `--once` runs a single poll cycle and exits, which is convenient for cron-style supervision or debugging.

## Operational characteristics

| Concern | Behavior |
|---|---|
| **Concurrency** | One ticket at a time by default (`max_concurrent_agents: 1`); raise carefully — each agent run can spawn dev servers and a browser. |
| **Disk** | `workspaces/` grows over time; orphaned workspaces (deleted tickets) are renamed aside automatically. Periodic pruning recommended. |
| **Slack modes** | Webhook-only (post) if no bot token; full bidirectional (post + read replies + upload evidence) with a bot token. |
| **GitHub auth** | Requires write access to the target repos to push branches and open draft PRs. |
| **Jira auth** | Basic auth with an API token (not a password). |
| **Recovery** | Crash-safe: state is re-derived from Jira on restart; in-flight tickets resume from their Jira state. |

## Running cadence

The daemon polls Jira on a fixed interval (default ~15s), processing eligible tickets and servicing human-review comments and Slack replies between polls. Because all decisions are gated on human review, the effective throughput is bounded by reviewer attention, not by the agent — which is the intended design.
