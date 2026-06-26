# Symphony — Observability

Because Symphony acts autonomously on a live codebase, it is built to be fully legible: every run is traceable, every decision is logged, and the human-facing state is always mirrored to Slack and Jira.

---

## Logs

| File | Contents |
|---|---|
| `logs/symphony.log` | Main daemon log — one timestamped line per significant action (poll, pickup, transition, label change, notification). |
| `logs/<ticket>-<ts>.agent.log` | The complete stdout/stderr of a single agent run, captured verbatim for post-hoc inspection. |
| `logs/validation-<workspace>-<ts>.log` | Output of the repo build/test command for that run. |
| `logs/launchd.out.log` / `.err.log` | Supervisor output on macOS (journald on the VM). |

## Persistent state files

These small JSON files make the daemon crash-safe and prevent duplicate action:

| File | Purpose |
|---|---|
| `logs/review-comment-state.json` | IDs of Jira comments already processed (bounded list) — prevents re-acting on the same feedback after a restart. |
| `logs/failure-retry-state.json` | Per-ticket auto-retry attempt counts and last-attempt timestamps — enforces the retry cap and cooldown. |
| `logs/slack-thread-state.json` | The Slack thread timestamp per ticket — keeps all updates for a ticket in one thread. |

Note that these are *caches/dedup ledgers*, not the source of truth. The authoritative state is always Jira; deleting these files at worst causes a one-time re-post, never lost work.

## Human-facing telemetry

- **Slack, thread-per-ticket.** Each ticket gets a dedicated thread that narrates its lifecycle: agent started, rework started, human-review ready (with evidence), blockers/failures, and PR phases. Reviewers follow a ticket's entire history in one place.
- **Jira as audit trail.** Status transitions, labels, attached evidence, and Symphony's own comments make the ticket history a complete, timestamped record of what happened and who approved it.

## Following a run

```
# tail the daemon
tail -f logs/symphony.log

# inspect a specific agent run end-to-end
less logs/<TICKET>-<timestamp>.agent.log

# on the VM
sudo journalctl -u <service> -f
```

## Process supervision signals

During an agent run the daemon actively supervises:

- **Timeout** — the agent is bounded by a wall-clock timeout; on expiry the process tree is terminated.
- **Dev-server watchdog** — long-lived dev servers are detected and killed after evidence capture + grace.
- **Ticket-deletion watchdog** — if the ticket disappears mid-run, the run is abandoned cleanly.
- **Exit-code semantics** — distinct codes distinguish success, timeout, ticket-deleted, and generic agent failure, each mapping to a specific Jira label and Slack message.

The guiding principle: an operator should always be able to answer "what is Symphony doing right now, and why?" from Jira, Slack, and the logs alone.
