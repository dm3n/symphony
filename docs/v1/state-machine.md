# Symphony — The Jira-Native State Machine

Symphony has no database. Its entire state machine is expressed in **Jira statuses and labels**. This is the single most important design decision in the system: reviewers interact with the tool they already use, the daemon can crash and resume losslessly, and the "current state" is always exactly what a human sees in Jira.

---

## 1. States (statuses) and signals (labels)

**Pickup signals** — Symphony will start implementation when a ticket is in any of these:
- Status: `Selected for Development`, `Ready for Agent`, `Rework`, `In Progress`
- Label: `agent-ready`, `agent-rework`

**Human-review gate** — a *blocker* for pickup; only reviewer comments act here:
- Status: `human review`  •  Label: `agent-human-review`

**PR-approval signals** — switch the worker into the PR phase instead of implementation:
- Status: `PR Submitted`, `Approved for PR`, `Ready for PR`, `PR Approved`, `PR`
- Label: `agent-pr-approved`

**Terminal / dedupe signals** — prevent repeated action:
- Label: `agent-pr-submitted` (PR already created — never create again)
- Status category: `Done`

**Failure signals** — explicit, never silent; eligible for bounded auto-retry:
- `agent-run-failed` — the agent exited non-zero
- `agent-validation-failed` — the build/test command failed
- `agent-orchestrator-error` — an unhandled exception in Symphony itself
- `agent-needs-video` — implementation finished but no valid evidence was produced
- `agent-cross-repo-needed` — implementation finished but a required repo was untouched

## 2. The full lifecycle

```
        ┌─────────────┐
        │   Backlog   │  human authors ticket
        └──────┬──────┘
               │ human: "Selected for Development" / +agent-ready
               ▼
        ┌─────────────┐     poll (~15s) sees pickup signal
        │   PICKUP    │
        └──────┬──────┘
               ▼
        ┌─────────────┐  isolate workspace · analyze scope · render acceptance contract
        │ IMPLEMENT   │  run agent (supervised) · commit to agent/<ticket> branch
        └──────┬──────┘
               ▼
        ┌─────────────┐  run repo build/test
        │  VALIDATE   │──fail──▶ +agent-validation-failed · notify · stop (retry-eligible)
        └──────┬──────┘
               ▼ pass
        ┌─────────────┐  gather + integrity-check evidence · squash branch (evidence excluded)
        │  EVIDENCE   │──none──▶ +agent-needs-video · notify · stop (retry-eligible)
        └──────┬──────┘
               ▼
        ┌─────────────┐  attach evidence · +agent-human-review · status → "human review"
        │HUMAN REVIEW │  baseline existing comments · notify Slack thread
        └──────┬──────┘
               │
   ┌───────────┼─────────────────────────────┐
   │           │                             │
 question    rework                        approve
   │           │                             │
   ▼           ▼                             ▼
 answer    +agent-rework, −agent-human-review   human moves to PR-approval status/label
 in Jira;  status → Rework/In Progress;          │
 stay in   re-run agent ─────────────┐           ▼
 review     (loop to IMPLEMENT)       │     ┌───────────┐  squash · force-with-lease push
                                      │     │    PR     │  gh pr create --draft · link in Jira
                                      │     └─────┬─────┘  +agent-pr-submitted (dedupe)
                                      │           ▼
                                      │     awaits human GitHub merge (out of scope for Symphony)
                                      └───────────────────────────────────────────────┘
```

## 3. The reviewer-feedback classifier

The hardest part of a human-in-the-loop agent loop is interpreting natural-language feedback correctly. Misread a change request as a question and the work stalls; misread "thanks" as a change request and the agent re-runs needlessly. Symphony resolves this with a layered classifier:

| Intent | Detection (heuristics) | Action |
|---|---|---|
| **Question** | starts with what/why/how/can/should/is/does… or contains `?` | Post an answer as a Jira comment; **stay** in human review |
| **Action request (question-shaped)** | a question that also contains an imperative + change verb ("can you **make** the header **smaller**?") | Treat as **rework** |
| **Rework** | change verbs: change, fix, adjust, move, remove, add, make, align, spacing, color, bigger, smaller, wrong, broken, should, needs… | +`agent-rework`, transition to Rework, re-run agent with a **focused brief** |
| **Approval** | looks good, lgtm, approved, ship it, go ahead | Log; take no action (wait for the human to move the status) |
| **Neutral** | very short positives: ok, thanks, cool | Record as processed; no follow-up |

Supporting mechanics that keep this reliable:

- **Comment baselining.** On the first handoff to human review, every pre-existing comment is marked processed, so historical discussion never re-triggers the agent.
- **State tracking.** Processed comment IDs are persisted (bounded list) so a restart never re-acts on the same comment.
- **Focused rework brief.** When rework is requested, the response Symphony generates back to the agent includes the required-repo coverage and the acceptance criteria that match the reviewer's keywords — keeping the re-run scoped to the actual ask.
- **Slack parity.** Replies in the ticket's Slack thread are mirrored into Jira and run through the identical classifier, so the medium doesn't change the behavior.

## 4. Why express state in Jira at all?

Three concrete payoffs:

1. **Zero-friction review UX.** Non-technical reviewers approve work by dragging a card or typing a comment — no bespoke dashboard, no new tool.
2. **Crash-safe by construction.** Because state is re-derived from Jira on every poll, the daemon is effectively stateless. Kill it mid-run and restart; it picks up exactly where Jira says things stand.
3. **Auditability.** The ticket history *is* the audit log: who approved, what evidence was attached, when the PR was opened. Nothing important happens off the record.
