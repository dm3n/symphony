# Symphony — Security & Trust Model

Symphony runs an autonomous agent with write access to source repositories. Its security posture is built around one principle: **bound the blast radius and keep a human as the only approval authority.**

---

## The authority boundary

| The agent **may** | The agent **may not** |
|---|---|
| Create an isolated workspace | Merge any code |
| Implement and commit to its own `agent/<ticket>` branch | Open a ready-for-review PR (drafts only) |
| Run the repo's build/test | Force-push without a lease |
| Capture evidence | Push to protected branches |
| Push its branch and open a **draft** PR after human approval | Approve its own work |

Every state advance that matters — reaching review, opening a PR, merging — requires a human action in Jira. The agent's autonomy is real but strictly upstream of all decisions.

## Secrets handling

- All credentials live in a `.env` file that is **never committed** (enforced via `.gitignore` and the deploy script's upload excludes).
- On the production VM the `.env` is `0600`, owned by a dedicated unprivileged service user.
- Secrets are read from the environment at startup; they are not logged. Logs capture actions and agent output, not credential values.
- Jira uses an API token (not a password); GitHub uses a scoped token; Slack uses a webhook or bot token.

## Blast-radius controls

- **Draft-only PRs** mean nothing can reach `main`/`development` without human review and merge on GitHub.
- **`--force-with-lease`** prevents the agent from ever clobbering commits it didn't expect.
- **Squash + evidence exclusion** keeps history clean and ensures local artifacts (screenshots, logs, build output) never enter the repo.
- **Pinned commit identity** makes every change auditable to a single, intended identity.
- **Single-instance lock** prevents two daemons from racing on the same tickets.
- **Idempotent labeling** prevents duplicate PRs and duplicate comment responses.

## Confidentiality

This public repository documents Symphony's **architecture and engineering**, not its employer-proprietary deployment. Deliberately excluded:

- private repository URLs and internal project keys
- the Jira instance and any organization identifiers
- all credentials, tokens, and `.env` contents
- any customer, investor, or employee data

The sanitized [`reference/`](../reference) material shows the *shape* of the configuration and interfaces without exposing any real values.

## Failure containment

Because every failure maps to an explicit label and notification — and because no failure path can merge code or force-push unsafely — the worst-case outcome of any malfunction is a clearly-marked, un-merged draft PR plus a Slack alert. There is no path from an agent error to a production change without a human in between.
