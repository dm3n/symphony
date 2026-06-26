# Symphony — Production Hardening

The difference between a demo and a system you trust to operate on a live codebase is entirely in the failure modes. Symphony is engineered so that the *worst* it can do is leave a clearly-labeled, un-merged draft PR and a Slack message. This document catalogs the safety engineering.

---

## Git safety

- **`--force-with-lease`, never `--force`.** A normal push is attempted first; on a non-fast-forward it retries with `--force-with-lease`. If the lease is stale, it fetches and retries once; if it still can't prove safety, it **aborts** rather than clobbering someone else's commits.
- **Squash before review.** The agent branch is soft-reset to the base branch and all source changes are squashed into a single commit. Evidence files are explicitly unstaged so they can never enter history.
- **Pinned commit identity.** Author and committer identity are pinned per-workspace via `git config` *and* the `GIT_AUTHOR_*` / `GIT_COMMITTER_*` environment variables, so authorship is consistent and auditable and never silently attributed to a stray local identity.
- **Draft PRs only.** `gh pr create --draft` — Symphony never opens a ready-for-review PR. Human technical review always happens on the real GitHub PR afterward.
- **Idempotent PRs.** After creating a PR, the `agent-pr-submitted` label is applied; the pickup check skips any ticket carrying it, so a PR is never created twice across poll cycles.

## Evidence integrity

- **Minimum-size thresholds.** Images must exceed a small floor and videos a larger one; trivial or empty files are rejected. This blocks the failure mode where an agent "produces evidence" that is actually a near-empty placeholder.
- **No synthetic fallbacks.** Policy and prompt both forbid text-only or generated stand-in evidence; only real screenshots/video of the running result count.
- **Ranked selection.** Evidence is ranked (images preferred, then most-recent) and capped to a handful of files for attachment, so reviewers see the most relevant proof first.
- **Hard gate.** If no valid evidence exists after implementation, the ticket is labeled `agent-needs-video` and **does not** advance to human review.

## Scope correctness

- **Preflight scope analysis.** Before implementation, the ticket is classified single- vs cross-repo by matching its text against per-repo term lists, producing the exact set of repos that must change.
- **Cross-repo review critic.** After implementation, if a cross-repo ticket's changed repos don't cover the required set, the ticket is blocked with `agent-cross-repo-needed` and a message explaining what's missing — instead of handing a half-done change to a reviewer.
- **Acceptance contracts.** Acceptance criteria are parsed out of the ticket and embedded as an explicit verification checklist in the agent prompt, with an instruction to verify each item before handoff.

## Process hygiene

- **Recursive process-tree cleanup.** When the agent must be killed (timeout, ticket deletion, shutdown), Symphony walks the process tree and terminates all descendants (dev servers, headless Chromium), escalating `SIGTERM` → `SIGKILL` after a grace period. No zombie node/npm/chromium processes.
- **Dev-server watchdog.** During an agent run, Symphony watches for long-lived dev servers (`npm run dev`, `next dev`, `vite`, `react-scripts start`) and kills them after evidence is captured plus a grace window — preventing resource leaks and runaway ports.
- **Ticket-deletion watchdog.** If a ticket is deleted mid-run, the agent process is terminated cleanly and the run is abandoned without side effects.

## Failure handling

- **Explicit failure labels.** Every failure class maps to a label (`agent-run-failed`, `agent-validation-failed`, `agent-orchestrator-error`, `agent-needs-video`, `agent-cross-repo-needed`) and a Slack notification. Failures are never silent passes.
- **Bounded auto-retry with cooldown.** Failed tickets can be auto-retried up to a configured maximum, with a cooldown between attempts, and only from the human-review state — preventing tight retry loops. Attempt counts and timestamps persist to disk.
- **Validation gate.** The repo's real build/test command must pass before a ticket can reach review; a failure blocks handoff and labels the ticket.

## Runtime correctness

- **Runtime pinning.** The launcher pins the Node version required by native backend dependencies before spawning the agent, eliminating a whole class of "works on my machine" build failures.
- **Preflight environment checks.** On startup Symphony validates: credentials present, required CLIs (`git`, `gh`, the agent, `node`) on `PATH`, the correct runtime version, all repo remotes reachable, and the authenticated GitHub identity matches the expected account. It refuses to run misconfigured.
- **Single-instance lock.** An `fcntl` lockfile guarantees exactly one daemon; a duplicate invocation exits cleanly.

## Design-system guardrails

For frontend tickets, the agent prompt carries explicit, non-negotiable UI rules — preserve design tokens, use the established component primitives, no global font/color/spacing changes, no decorative drift. This moves design consistency *upstream* into the agent's instructions rather than relying on catching regressions in review.

---

### The safety invariant

Taken together, these controls enforce one invariant: **Symphony can never merge code, never force-clobber a branch, never advance unverified work, and never fail silently.** The maximum blast radius of any malfunction is a labeled, un-merged draft PR plus a Slack notification — which is exactly what you want from an autonomous system pointed at production.
