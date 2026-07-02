---
name: jira
description: |
  Use Symphony's `jira_request` client tool for raw Jira Cloud REST
  operations such as reading issues, editing the workpad comment,
  transitioning status, and attaching PR links.
---

# Jira REST

Use this skill for all Jira work during Symphony app-server sessions.

## Primary tool

Use the `jira_request` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Jira auth (email + API token) for the session.

Tool input:

```json
{
  "method": "GET | POST | PUT | DELETE (default GET)",
  "path": "/rest/api/2/... (may include a query string)",
  "body": { "optional": "JSON body for POST/PUT" }
}
```

Tool behavior:

- One REST call per tool invocation.
- 2xx responses return the decoded JSON body (or empty body for 204).
- Non-2xx responses fail the tool call with the HTTP status.
- Use the v2 API (`/rest/api/2/...`) so descriptions and comments are plain
  text (Jira wiki markup) rather than Atlassian Document Format.

## Common workflows

### Read an issue

```json
{ "path": "/rest/api/2/issue/AD-46?fields=summary,description,status,labels,comment,issuelinks,assignee" }
```

### Search with JQL

```json
{
  "method": "POST",
  "path": "/rest/api/2/search/jql",
  "body": { "jql": "project = AD AND status = \"In Progress\"", "maxResults": 50, "fields": ["summary", "status"] }
}
```

### Find the workpad comment

Read the issue with `fields=comment`, then scan
`fields.comment.comments[]` for a `body` starting with `## Codex Workpad`.
Remember the comment `id`.

### Create the workpad comment

```json
{
  "method": "POST",
  "path": "/rest/api/2/issue/AD-46/comment",
  "body": { "body": "## Codex Workpad\n..." }
}
```

### Update (edit in place) the workpad comment

```json
{
  "method": "PUT",
  "path": "/rest/api/2/issue/AD-46/comment/10123",
  "body": { "body": "## Codex Workpad\n<updated content>" }
}
```

### Delete the workpad comment (Rework reset)

```json
{ "method": "DELETE", "path": "/rest/api/2/issue/AD-46/comment/10123" }
```

### Transition status

Always list transitions first and match on the target status name; never
hardcode transition ids:

```json
{ "path": "/rest/api/2/issue/AD-46/transitions" }
```

Then post the matching transition id:

```json
{
  "method": "POST",
  "path": "/rest/api/2/issue/AD-46/transitions",
  "body": { "transition": { "id": "31" } }
}
```

AD board statuses: `Backlog`, `Selected for Development`, `In Progress`,
`human review` (lowercase), `Rework`, `Merging`, `Done`.

### Attach a GitHub PR to an issue

Use a remote link (idempotent via `globalId`):

```json
{
  "method": "POST",
  "path": "/rest/api/2/issue/AD-46/remotelink",
  "body": {
    "globalId": "github-pr-<owner>-<repo>-<number>",
    "object": {
      "url": "https://github.com/<owner>/<repo>/pull/<number>",
      "title": "PR #<number>: <title>",
      "icon": { "url16x16": "https://github.com/favicon.ico" }
    }
  }
}
```

### Read attached PR links

```json
{ "path": "/rest/api/2/issue/AD-46/remotelink" }
```

### Create a follow-up issue

```json
{
  "method": "POST",
  "path": "/rest/api/2/issue",
  "body": {
    "fields": {
      "project": { "key": "AD" },
      "issuetype": { "name": "Task" },
      "summary": "<clear title>",
      "description": "<description with acceptance criteria>",
      "labels": ["mitch-fe"]
    }
  }
}
```

New issues land in `Backlog` by default. Link it to the current issue:

```json
{
  "method": "POST",
  "path": "/rest/api/2/issueLink",
  "body": {
    "type": { "name": "Relates" },
    "inwardIssue": { "key": "AD-46" },
    "outwardIssue": { "key": "AD-99" }
  }
}
```

Use `{ "type": { "name": "Blocks" } }` with the current issue as
`inwardIssue` when the follow-up depends on the current issue.

## Usage rules

- Use `jira_request` for all Jira reads/writes; do not shell out with raw
  tokens or invent alternate auth paths.
- Comment bodies are Jira wiki markup, not GitHub Markdown. Checklists render
  fine as plain `- [ ]` text lines; keep the workpad structure exactly as the
  workflow template specifies.
- For state transitions, always resolve the transition id by target status
  name first (case-insensitive match on `to.name`).
- File attachments are not supported through `jira_request` (multipart). Put
  evidence in the workpad as text/command output, and media on the GitHub PR.
- Keep request payloads narrowly scoped; ask only for the fields you need.
