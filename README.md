# Symphony @ Finsider

Autonomous software delivery for Finsider, built on
[openai/symphony](https://github.com/openai/symphony) — OpenAI's open-source
spec + reference implementation for orchestrating Codex agents from a task
board — extended with a **native Jira adapter** so it lives on the Finsider
Jira `AD` board.

Every actionable ticket on the AD board gets a Codex agent running in an
isolated workspace until the work is reviewed, approved, and landed. Humans
manage the board; Symphony manages the work.

## Architecture

```
Jira AD board  <──poll/comment/transition──  Symphony (Elixir, upstream/)
                                                │
                                    per-issue workspaces
                                                │
                                        codex app-server
                                     (agents + jira_request tool
                                      + gh + full dev toolchain)
                                                │
                                    GitHub PRs → finsider-ai/Mitch-fe
                                                 finsider-ai/Mitch-be
```

- `upstream/` — git subtree of `openai/symphony` (spec + Elixir reference
  implementation) plus our Jira additions:
  - `elixir/lib/symphony_elixir/jira/client.ex` — Jira Cloud REST client
    (search/jql polling, comments, transitions, raw REST).
  - `elixir/lib/symphony_elixir/jira/adapter.ex` — `Tracker` behaviour
    implementation (`tracker.kind: jira`).
  - `jira_request` dynamic tool injected into every Codex session (replaces
    `linear_graphql` when the tracker is Jira).
- `workflows/` — one WORKFLOW.md per target repo. Both watch the same `AD`
  project and route by label: `mitch-fe` / `mitch-be`.
- `skills/jira/` — the `jira` agent skill (copied into each workspace at
  creation, alongside upstream's `commit`, `push`, `pull`, `land`, `debug`).
- `ops/` — installer, start script, upstream auto-update, launchd services.
- `docs/v1/` — the previous custom harness (retired 2026-07-02), kept for
  reference.

## Board contract (Jira `AD`)

| Status | Meaning | Who moves it |
|---|---|---|
| Backlog | Not ready; Symphony ignores | Human |
| Selected for Development | Queued for an agent | Human |
| In Progress | Agent implementing | Agent |
| human review | PR attached + validated, awaiting human | Agent |
| Rework | Reviewer wants a different approach (full reset) | Human |
| Merging | Approved; agent lands the PR | Human |
| Done | Merged/closed | Agent |

Routing labels: `mitch-fe` (frontend instance), `mitch-be` (backend instance).
A ticket must carry one of these labels to be picked up. Progress lives in a
single persistent `## Codex Workpad` comment per issue; the PR is attached as
a remote link.

## Install / run

```bash
ops/install.sh          # toolchain (mise: erlang 28 + elixir 1.19), build, tests, launchd
```

Services (auto-start at login, keep-alive):

- `com.finsider.symphony.mitch-fe` — dashboard at http://127.0.0.1:4310
- `com.finsider.symphony.mitch-be` — dashboard at http://127.0.0.1:4311
- `com.finsider.symphony.update` — weekly upstream sync (Mon 05:00)

Secrets come from `~/finsider-platform/agentic-development/.env`
(`JIRA_EMAIL`, `JIRA_API_TOKEN`; optional `SLACK_WEBHOOK_URL`,
`GITHUB_TOKEN`). Nothing secret is committed to this repo.

Codex auth: `codex login` (Codex subscription via ChatGPT sign-in, or API
key). Agents run with `approval_policy: never`, workspace-write sandbox, and
network access inside their isolated per-issue workspace.

## Staying current with upstream

`upstream/` is a squashed git subtree. The weekly `ops/update-upstream.sh`:

1. `git subtree pull` from `openai/symphony@main`
2. rebuild + full `mix test`
3. green → push + restart services; red or conflict → roll back and notify
   Slack

Run it manually any time: `ops/update-upstream.sh`.

## Manual ops

```bash
# start one instance in the foreground (debugging)
ops/start-symphony.sh workflows/WORKFLOW.mitch-fe.md 4310

# restart services
launchctl kickstart -k gui/$(id -u)/com.finsider.symphony.mitch-fe
launchctl kickstart -k gui/$(id -u)/com.finsider.symphony.mitch-be

# stop everything
launchctl bootout gui/$(id -u)/com.finsider.symphony.mitch-fe
launchctl bootout gui/$(id -u)/com.finsider.symphony.mitch-be

# logs
tail -f logs/WORKFLOW.mitch-fe/*.log logs/launchd.mitch-fe.err.log
```

## History

- **v2 (current)** — OG openai/symphony + native Jira adapter. This revamp.
- **v1** (`docs/v1/`) — custom Python harness (2,300 LOC orchestrator) driving
  coding agents against the AD board with screenshot/video evidence gating.
  Retired 2026-07-02; archived at
  `~/Archive/agentic-symphony-claude-harness-20260702/`.
