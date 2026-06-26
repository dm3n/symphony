# Symphony — Design Rationale

Why Symphony is built the way it is. Each decision below was a deliberate response to a specific failure mode of naive "let an agent code for you" systems.

---

## 1. Why supervised autonomy, not full autonomy

The founding insight comes from my paper [*Uncertainty Propagation in Tree-Structured Language Model Reasoning*](https://github.com/dm3n/uncertainty-propagation). It proves that a single chain of `n` reasoning steps succeeds with probability `∏(1 − θᵢ)`, which decays **exponentially** in `n`. Even at a low per-step error rate, a long autonomous run is unreliable by construction: a 48-step chain at θ ≈ 0.12 succeeds essentially never (~0.2%), while a depth-3 tree using the *same* compute succeeds ~98%.

The engineering implication is direct: **don't ship from one long unsupervised chain.** Symphony decomposes delivery into short, individually-verified, human-gated units. Each unit keeps per-step failure low; the human-review gate is the aggregation step. Symphony is, in effect, the tree-structured reliability regime applied to software delivery — the theory turned into infrastructure.

## 2. Why Jira is the state machine

Alternatives considered: an external job queue, a database, a bespoke web app.

Jira won because:
- **The reviewers already live there.** Approval is dragging a card or typing a comment — no new tool to learn.
- **It makes the daemon stateless.** State is re-derived from Jira each poll, so the process is crash-safe and trivially restartable.
- **The ticket history is the audit log.** Who approved, what evidence, when the PR opened — all on the record automatically.

The cost is that Jira's API becomes a hard dependency and the "schema" is a set of statuses/labels rather than typed columns. That trade was worth it for the operational simplicity.

## 3. Why evidence-gated PRs

The single biggest risk with agent-written code is **plausible-but-wrong** output that passes a glance. Requiring screenshots/video of the *running* result before a human ever sees the ticket — and requiring human sign-off on that evidence before a PR exists — forces the system to prove the change works, not just that it compiles. It also lets non-technical reviewers contribute meaningfully: they can judge "does this look right?" without reading a diff.

## 4. Why intent classification of feedback

A human-in-the-loop is only as good as the loop's ability to interpret the human. The naive version (treat every comment as rework) makes reviewers afraid to ask questions; the other naive version (only act on explicit labels) makes the loop slow and bureaucratic. Classifying comments into question / rework / approval / neutral — including the subtle "question-shaped action request" case — is what makes the loop feel natural while staying correct.

## 5. Why a single stdlib Python file

No framework, no SDK, no ORM. The orchestrator is ~2,300 lines of standard-library Python. Reasons:
- **Auditability** — a reviewer (or a security team) can read the whole system.
- **Portability** — it runs identically on macOS and a bare Ubuntu VM with nothing but Python and a few CLIs.
- **Longevity** — no dependency churn; nothing to break on an upstream major-version bump.

For a system that operates autonomously on production code, "boring and legible" is a feature.

## 6. Why two deployment targets

Local (LaunchAgent) is the development and demo environment — fast to iterate, easy to watch. The GCP/systemd VM is the always-on production runner — survives laptop sleep, runs around the clock, isolated under a dedicated service user. Same orchestrator, different supervisor; the code doesn't know or care which it's under.

## 7. Why draft PRs only

Symphony deliberately stops at a **draft** PR. The final technical review and merge happen on GitHub, by a human, on the real diff and CI. This keeps the agent firmly on the implementation side of the authority boundary and means there is no path from an agent run to a merged change without explicit human action. It is the most important single guardrail in the system.

---

### The thesis in one sentence

Symphony encodes a specific, defensible belief about AI in production: **today's agents are excellent implementers and unreliable deciders — so give them all the implementation power you can, and none of the decision power.** Everything else in the design follows from that.
