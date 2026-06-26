# Symphony — Architecture

Symphony is a single long-running daemon that orchestrates a coding agent against a live, multi-repository codebase, using Jira as its source of truth and a human as its approval authority. This document describes the system end to end.

> Employer-internal identifiers (private repo URLs, the Jira instance, project keys) are generalized throughout. The architecture is faithful; the specifics are sanitized.

---

## 1. Design tenets

1. **The ticket is the single source of truth.** All lifecycle state lives in Jira — status and labels *are* the control flow. There is no external queue, scheduler, or database to keep in sync. If Jira says a ticket is in `human review`, it is; if a label says `agent-pr-submitted`, the PR exists.
2. **The agent implements; the human decides.** The agent gets real power (isolated workspaces, full implementation, validation, branch and PR operations) but zero approval authority. Scope completeness, visual correctness, and merge approval are always human calls.
3. **Nothing advances without evidence.** A ticket cannot reach a human reviewer without attached visual proof that the change runs. A PR cannot be created without a human having seen that proof.
4. **Fail safe, not silent.** Every failure mode (agent crash, build failure, missing evidence, incomplete cross-repo work) maps to an explicit Jira label and a Slack notification — never a quiet pass.
5. **Idempotent polling.** The daemon re-derives all state from Jira on every poll, so it can crash and restart at any moment without losing or duplicating work.

## 2. Component map

```
┌──────────────────────────── Symphony daemon (Python 3) ────────────────────────────┐
│                                                                                     │
│  ┌───────────────┐   ┌───────────────────┐   ┌──────────────────────────────────┐  │
│  │ Polling loop  │   │ Review handlers    │   │ Per-ticket worker (thread pool)  │  │
│  │ poll_once()   │──▶│ Jira comments +    │   │  ├─ phase detection (impl|pr)    │  │
│  │ JQL every ~15s│   │ Slack replies →    │   │  ├─ workspace isolation          │  │
│  │ eligibility   │   │ intent classifier  │   │  ├─ scope analysis               │  │
│  │ orphan cleanup│   └───────────────────┘   │  ├─ acceptance-contract render    │  │
│  └───────────────┘                           │  ├─ supervised agent run          │  │
│                                              │  ├─ validation (build/test)       │  │
│  ┌───────────────┐   ┌───────────────────┐  │  ├─ evidence capture + integrity  │  │
│  │ Jira client   │   │ Failure recovery   │  │  ├─ human-review handoff          │  │
│  │ (REST v3)     │   │ bounded auto-retry │  │  └─ PR phase (squash/push/PR)     │  │
│  └───────────────┘   └───────────────────┘  └──────────────────────────────────┘  │
│                                                                                     │
│  Concurrency: fcntl single-instance lock · ThreadPoolExecutor(max_concurrent)       │
└─────────────────────────────────────────────────────────────────────────────────────┘
        │                 │                  │                    │
        ▼                 ▼                  ▼                    ▼
   Jira Cloud         GitHub (gh)         Slack              Local filesystem
   (state of record)  (draft PRs)         (thread/ticket)    (workspaces, evidence, logs, state)
```

## 3. The orchestrator

A single Python 3 process (~2,300 lines), deliberately built on the **standard library only** (`urllib`, `subprocess`, `threading`/`concurrent.futures`, `fcntl`, `pathlib`, `json`). No web framework, no ORM, no agent SDK. This keeps the runtime dependency-free, auditable, and trivially portable between macOS and a Linux VM.

Key internal modules (responsibilities, not proprietary logic):

| Area | Responsibility |
|---|---|
| **Jira client** | JQL search, comment read/write, status transitions, label add/remove, attachment upload; converts Atlassian Document Format → plain text. |
| **Issue model** | A typed view of a ticket: key, title, plaintext description, status, status category, labels, URL. |
| **Scope analyzer** | Reads title/description/acceptance-criteria and matches against per-repo term lists to decide single- vs cross-repo and the exact set of repos that must change. |
| **Contract renderer** | Parses acceptance criteria and injects them, plus the target repo and scope verdict, into the agent's `WORKFLOW` prompt template. |
| **Workspace manager** | Per-ticket isolated git clone on an `agent/<ticket>` branch; pinned git identity; git excludes so evidence never gets committed. |
| **Agent runner** | Spawns the coding agent, supervises its process tree, and enforces timeout/exit-code semantics. |
| **Evidence finder** | Collects screenshots/video with minimum-size thresholds; ranks and selects for attachment. |
| **Validation runner** | Runs the repo's real build/test command with a timeout; blocks review on failure. |
| **Review handlers** | Poll Jira comments and Slack replies, classify intent, and act; state-tracked to avoid double-processing. |
| **PR manager** | Squash → safe push → draft PR → terminal label to prevent duplicates. |
| **Failure recovery** | Bounded auto-retry with cooldown for failed runs, with on-disk attempt tracking. |

## 4. Data flow for one ticket

```
1. poll_once() runs a JQL query for non-Done tickets in the project, newest-priority first.
2. For each eligible ticket, a worker is dispatched (bounded by max_concurrent_agents).
3. Phase detection: PR-approved labels/status → "pr" phase; otherwise → "impl" phase.
4. (impl) Workspace is isolated; scope is analyzed; the acceptance contract is rendered.
5. The coding agent runs under supervision, implements, and commits locally to the agent branch.
6. Validation runs the repo build/test. On failure → label agent-validation-failed, notify, stop.
7. Evidence is gathered from the workspace; integrity-checked (min sizes); top items selected.
8. The branch is squashed (evidence excluded); the ticket is moved to human review with evidence attached.
9. The reviewer comments. The classifier routes: question → answer in Jira; rework → re-run; approval → wait.
10. (pr) On human approval, the branch is force-with-lease pushed and a DRAFT PR is created and linked.
11. The agent-pr-submitted label is applied so the PR is never created twice.
```

## 5. Integrations

- **Jira Cloud REST v3** — the system of record. Reads via JQL; writes status transitions, labels, comments, and file attachments. All lifecycle state is expressed here.
- **GitHub via the `gh` CLI** — used only for **draft** PR creation and existence checks. Symphony never opens a ready-for-review PR; technical review happens on the real PR downstream.
- **Slack** — one thread per ticket. Posts lifecycle events (agent started, rework started, human-review ready, blockers/failures, PR phases). With a bot token, it also **reads thread replies** and mirrors them back into Jira as comments, so reviewers can work entirely in Slack and the same classifier applies.
- **Coding agent (Claude Code)** — invoked headlessly with the rendered contract on stdin; output streamed to a per-run log.
- **Playwright (Node)** — headless browser that records a short video and screenshot of the running UI as review evidence (Xvfb-backed on Linux).

## 6. Concurrency & lifecycle

- **Single instance** — an `fcntl` exclusive lock on a lockfile guarantees one daemon; a second invocation exits cleanly (no double-processing).
- **Bounded parallelism** — a `ThreadPoolExecutor` caps concurrent agents (default 1; configurable). Running futures are tracked by ticket key.
- **Self-healing** — orphaned workspaces (whose tickets no longer exist) are renamed aside on each poll.
- **Graceful shutdown** — `SIGINT` stops accepting new work and lets running workers finish.

## 7. Storage layout

```
workspaces/<ticket>-<repo>/     isolated per-ticket git clone (agent branch)
evidence/<ticket>/              staged screenshots/video
logs/symphony.log               main daemon log
logs/<ticket>-<ts>.agent.log    full per-run agent output
logs/review-comment-state.json  processed Jira comment IDs (bounded)
logs/failure-retry-state.json   per-ticket auto-retry attempts + timestamps
logs/slack-thread-state.json    Slack thread id per ticket
.env                            secrets (never committed; 0600 on the VM)
```

See [state-machine.md](state-machine.md) for the control flow, [hardening.md](hardening.md) for the safety engineering, and [deployment.md](deployment.md) for how it runs in production.
