defmodule SymphonyElixir.Jira.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Jira.Client
  alias SymphonyElixir.Linear.Issue

  @base_url "https://finsider.atlassian.net"

  defp raw_issue(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "AD-46",
        "fields" => %{
          "summary" => "Fix login redirect",
          "description" => "Users bounce back to /login.",
          "status" => %{"name" => "In Progress"},
          "priority" => %{"name" => "High"},
          "labels" => ["Mitch-FE", "agent-ready"],
          "assignee" => %{"accountId" => "abc123"},
          "issuelinks" => [
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by", "outward" => "blocks"},
              "inwardIssue" => %{
                "key" => "AD-40",
                "fields" => %{"status" => %{"name" => "Done"}}
              }
            },
            %{
              "type" => %{"name" => "Blocks", "inward" => "is blocked by", "outward" => "blocks"},
              "outwardIssue" => %{
                "key" => "AD-50",
                "fields" => %{"status" => %{"name" => "Backlog"}}
              }
            }
          ],
          "created" => "2026-07-01T10:15:30.000-0400",
          "updated" => "2026-07-02T08:00:00.000+0000"
        }
      },
      overrides
    )
  end

  test "normalizes a Jira issue into the shared Issue struct" do
    issue = Client.normalize_issue_for_test(raw_issue(), @base_url)

    assert %Issue{} = issue
    assert issue.id == "AD-46"
    assert issue.identifier == "AD-46"
    assert issue.title == "Fix login redirect"
    assert issue.description == "Users bounce back to /login."
    assert issue.priority == 2
    assert issue.state == "In Progress"
    assert issue.branch_name == "ad-46-fix-login-redirect"
    assert issue.url == "https://finsider.atlassian.net/browse/AD-46"
    assert issue.assignee_id == "abc123"
    assert issue.labels == ["mitch-fe", "agent-ready"]
    assert issue.assigned_to_worker
    assert issue.created_at == ~U[2026-07-01 14:15:30.000Z]
    assert issue.updated_at == ~U[2026-07-02 08:00:00.000Z]
  end

  test "only inward 'is blocked by' links count as blockers" do
    issue = Client.normalize_issue_for_test(raw_issue(), @base_url)

    assert issue.blocked_by == [%{id: "AD-40", identifier: "AD-40", state: "Done"}]
  end

  test "issues without a key are dropped" do
    assert Client.normalize_issue_for_test(%{"fields" => %{}}, @base_url) == nil
  end

  test "missing optional fields normalize to safe defaults" do
    issue = Client.normalize_issue_for_test(%{"key" => "AD-1", "fields" => %{}}, @base_url)

    assert issue.title == nil
    assert issue.description == nil
    assert issue.priority == nil
    assert issue.labels == []
    assert issue.blocked_by == []
    assert issue.branch_name == "ad-1"
    assert issue.assigned_to_worker
  end

  test "matches transitions by target status name case-insensitively" do
    transitions = [
      %{"id" => "11", "to" => %{"name" => "Backlog"}},
      %{"id" => "51", "to" => %{"name" => "human review"}}
    ]

    assert Client.match_transition_for_test(transitions, "Human Review") == {:ok, "51"}
    assert Client.match_transition_for_test(transitions, "Merging") == {:error, {:transition_not_found, "Merging"}}
  end

  test "branch names are slugged and bounded" do
    assert Client.branch_name_for_test("AD-9", "Fix: weird   chars / (100%)") == "ad-9-fix-weird-chars-100"

    long_title = String.duplicate("very long title ", 10)
    branch = Client.branch_name_for_test("AD-9", long_title)
    assert String.length(branch) <= String.length("ad-9-") + 48
    refute String.ends_with?(branch, "-")
  end

  test "parses Jira timestamps with colonless offsets" do
    assert Client.parse_datetime_for_test("2026-07-02T10:15:30.000-0400") == ~U[2026-07-02 14:15:30.000Z]
    assert Client.parse_datetime_for_test(nil) == nil
    assert Client.parse_datetime_for_test("not-a-date") == nil
  end

  test "builds quoted JQL for project polling" do
    jql = Client.jql_for_test("AD", ["Selected for Development", "In Progress"])

    assert jql ==
             ~s(project = "AD" AND status in \("Selected for Development", "In Progress"\) ORDER BY created ASC)
  end
end
