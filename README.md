<h1 align="center">Symphony</h1>

<p align="center">
  <b>A Jira-native, evidence-gated, supervised-autonomy software-delivery runner.</b><br>
  Takes a product ticket from backlog to a reviewed, evidence-backed pull request — with a human in the loop at every decision.
</p>

<p align="center">
  <code>Python 3</code> · <code>Claude Code agent</code> · <code>Playwright evidence</code> · <code>Jira • GitHub • Slack</code> · <code>macOS LaunchAgent + GCP/systemd</code>
</p>

---

> **Author & architect:** Daniel Ray Edgar — designed and built as CTO of [Finsider](https://finsider.ai), where Symphony runs in the live engineering environment driving real product tickets to pull requests.
>
> **About this repository.** This is the **engineering design record** for Symphony — architecture, the Jira-native state machine, the production-hardening that makes it safe to point at a live codebase, the deployment topology, and sanitized reference interfaces. Employer-proprietary source, private repository identifiers, the Jira instance, and credentials are intentionally **not** published here. Everything below describes the design and the engineering decisions behind it.

---

## TL;DR

Symphony treats an LLM coding agent as a **capable but unprivileged developer**: it can implement, validate, and produce evidence — but it never holds approval authority. Every *decision* (is the scope complete? does the UI look right? can this merge?) is routed to a human, and Symphony makes that human's job trivial by attaching visual evidence and classifying their feedback automatically.

The result is **supervised autonomy**: dozens of tickets driven from a one-line description to an evidence-backed, review-gated draft PR, with the genuinely hard parts solved — safe git, process hygiene, cross-repo correctness, fake-evidence rejection, and bounded failure recovery.

```
ticket ─▶ scope analysis ─▶ acceptance contract ─▶ agent implements
      ─▶ validate (build/test) ─▶ capture screenshots/video
      ─▶ HUMAN REVIEW (evidence attached) ─▶ classify feedback
            ├─ question → answered in Jira, stays in review
            ├─ rework   → re-run agent with a focused brief
            └─ approve  → squash → force-with-lease push → draft PR
```

## Why it exists

This is the engineering counterpart to a piece of research I wrote — [*Uncertainty Propagation in Tree-Structured Language Model Reasoning*](https://github.com/dm3n/uncertainty-propagation). That paper proves that a single long autonomous chain of reasoning decays **exponentially** in reliability: at a 10% per-step error rate, ten steps is already a coin flip. The practical consequence is that you cannot trust one long agent run to ship code.

Symphony is the answer to that math. Instead of one long unsupervised chain, it decomposes delivery into **short, individually-verified, human-gated units** with hard evidence checkpoints. Each unit keeps per-step failure low; the human review gate aggregates across them. It is tree-structured reliability applied to software delivery.

## What makes it notable

| | |
|---|---|
| **Jira *is* the state machine** | No external queue or database. Ticket status + labels are the control flow; reviewers just use Jira (or Slack). |
| **Evidence-gated PRs** | No PR exists until implementation is done, the build passes, screenshots/video are attached, **and** a human approves. |
| **Intent-classified review** | "Should this use X?" (question) vs "Can you make it smaller?" (rework) vs "lgtm" (approval) are distinguished by heuristics, keeping the loop tight. |
| **Cross-repo scope critic** | Detects when a ticket needs changes across multiple repos and blocks review if coverage is incomplete. |
| **Safe by construction** | `--force-with-lease` only, pinned commit identity, recursive process-tree cleanup, fake-evidence rejection, single-instance file lock. |
| **Two production targets** | macOS LaunchAgent for local; an always-on GCP Compute Engine VM under systemd for production. |

## Documentation

| Doc | What's inside |
|---|---|
| [docs/architecture.md](docs/architecture.md) | The full system: components, data flow, the orchestrator, integrations, and the system diagram. |
| [docs/state-machine.md](docs/state-machine.md) | The Jira-native lifecycle — every status, label, transition, and the reviewer-feedback classifier. |
| [docs/hardening.md](docs/hardening.md) | The production-grade engineering: safe git, watchdogs, evidence integrity, failure recovery, scope critics. |
| [docs/deployment.md](docs/deployment.md) | macOS LaunchAgent and GCP/systemd deployment, environment checks, and operations. |
| [docs/observability.md](docs/observability.md) | Logging, persistent state files, process supervision, and how to follow a run. |
| [docs/security.md](docs/security.md) | Secrets handling, identity pinning, blast-radius controls, and the human-authority boundary. |
| [docs/design-rationale.md](docs/design-rationale.md) | The "why" behind every major decision, and the link to the reasoning-reliability research. |

Reference material: [`reference/config.reference.json`](reference/config.reference.json) (sanitized configuration schema) · [`reference/WORKFLOW.template.md`](reference/WORKFLOW.template.md) (the acceptance-contract prompt) · [`reference/orchestrator_interface.py`](reference/orchestrator_interface.py) (annotated interface skeleton).

## At a glance

- **~2,300-line** single-file Python 3 orchestrator, standard library only — no heavyweight agent framework.
- Drives a **Claude Code** agent headlessly with a rendered acceptance contract.
- **Playwright** captures screenshots/video of the running result as review evidence.
- Integrates **Jira Cloud** (state), **GitHub** via `gh` (draft PRs), and **Slack** (thread-per-ticket, bidirectional).
- Concurrency-safe via an `fcntl` file lock; bounded worker pool; graceful shutdown.

---

<sub>Part of the <a href="https://github.com/dm3n/portfolio">Daniel Edgar — AI Systems Portfolio</a>. Built and maintained by <a href="https://github.com/dm3n">@dm3n</a>.</sub>
