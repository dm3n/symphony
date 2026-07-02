defmodule SymphonyElixir.JiraDynamicToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.DynamicTool

  test "jira_request executes REST calls through the injected client" do
    response =
      DynamicTool.execute(
        "jira_request",
        %{"method" => "post", "path" => "/rest/api/2/issue/AD-1/comment", "body" => %{"body" => "hi"}},
        jira_client: fn method, path, body ->
          assert method == "POST"
          assert path == "/rest/api/2/issue/AD-1/comment"
          assert body == %{"body" => "hi"}
          {:ok, %{"id" => "10001"}}
        end
      )

    assert response["success"]
    assert response["output"] =~ "10001"
  end

  test "jira_request defaults to GET with no body" do
    response =
      DynamicTool.execute(
        "jira_request",
        %{"path" => "/rest/api/2/myself"},
        jira_client: fn method, path, body ->
          assert method == "GET"
          assert path == "/rest/api/2/myself"
          assert body == nil
          {:ok, %{"accountId" => "abc"}}
        end
      )

    assert response["success"]
  end

  test "jira_request rejects a missing path before calling Jira" do
    response =
      DynamicTool.execute(
        "jira_request",
        %{"method" => "GET"},
        jira_client: fn _method, _path, _body -> flunk("client should not be called") end
      )

    refute response["success"]
    assert response["output"] =~ "requires a non-empty `path`"
  end

  test "jira_request surfaces HTTP failures" do
    response =
      DynamicTool.execute(
        "jira_request",
        %{"path" => "/rest/api/2/myself"},
        jira_client: fn _method, _path, _body -> {:error, {:jira_api_status, 401}} end
      )

    refute response["success"]
    assert response["output"] =~ "HTTP 401"
  end
end
