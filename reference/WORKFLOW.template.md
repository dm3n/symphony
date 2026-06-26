# Symphony — Agent Acceptance Contract (template)

> This is the prompt template Symphony renders and feeds to the coding agent for each ticket.
> Tokens in `{{ ... }}` are substituted at runtime from the Jira ticket and scope analysis.
> This is a generalized reference — employer-specific rules are abstracted.

---

## Jira ticket
- **Key:** {{ issue.key }}
- **Title:** {{ issue.title }}
- **URL:** {{ issue.url }}
- **Status:** {{ issue.status }}
- **Target repo:** {{ repo.key }}
- **Target branch:** {{ repo.default_branch }} (work on `agent/{{ issue.key }}`)

## Description
{{ issue.description }}

## Symphony Acceptance Contract
- **Scope detected:** {{ scope }}  (single-repo | cross-repo)
- **Required repo coverage:** {{ required_repos }}
- **Acceptance criteria — verify EVERY item before handoff:**
{{ acceptance_criteria_checklist }}

## Operating rules (implementation phase)
1. Do **not** open or push a PR during implementation. Commit locally to `agent/{{ issue.key }}` only.
2. Implement the change and satisfy every acceptance criterion above.
3. Run the repo's validation command and ensure it passes.
4. **Produce real evidence** of the running result (screenshot and/or video). No text-only or synthetic evidence.
5. Stop any dev servers you start once evidence is captured.
6. Do **not** commit evidence, logs, build output, traces, or screenshots.

## Frontend design-system guardrails (if this is a UI ticket)
- Preserve existing design tokens (color, spacing, typography). No global theme changes.
- Use the established component primitives; do not introduce new UI frameworks.
- Keep the change scoped and visually consistent with the surrounding UI. No decorative drift.

## Definition of Done — implementation
- [ ] All acceptance criteria verified
- [ ] Validation (build/test) passes
- [ ] Local branch committed
- [ ] Real evidence captured for review
- [ ] Ready to hand back to human review

## Review loop
- If the reviewer asks a **question**, answer it; the ticket stays in human review.
- If the reviewer requests **changes**, address exactly those changes and re-capture evidence.

## PR phase (only after human approval)
- Rebase/squash onto `{{ repo.default_branch }}`, re-run validation.
- Open a **draft** PR (never ready-for-review) and link it back to the Jira ticket.
