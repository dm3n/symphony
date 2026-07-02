defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST client for polling candidate issues.

  Uses the v2 REST API so descriptions and comments are plain text
  (wiki markup) instead of Atlassian Document Format.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @issue_fields "summary,description,status,priority,labels,assignee,issuelinks,created,updated"
  @max_branch_slug_length 48

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      do_search(project_jql(tracker.project_slug, tracker.active_states), assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_settings(tracker) do
        do_search(project_jql(tracker.project_slug, normalized_states), nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        with :ok <- validate_tracker_settings(tracker),
             {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, issues} <- do_search(keys_jql(ids), assignee_filter) do
          {:ok, sort_issues_by_requested_ids(issues, ids)}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_key, body) when is_binary(issue_key) and is_binary(body) do
    case request(:post, "/rest/api/2/issue/#{encode_path(issue_key)}/comment", %{body: body}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_key, state_name)
      when is_binary(issue_key) and is_binary(state_name) do
    with {:ok, transition_id} <- resolve_transition_id(issue_key, state_name),
         {:ok, _response} <-
           request(:post, "/rest/api/2/issue/#{encode_path(issue_key)}/transitions", %{
             transition: %{id: transition_id}
           }) do
      :ok
    end
  end

  @doc """
  Raw Jira REST request using Symphony's configured auth.

  `path` must start with `/rest/`. `body` is JSON-encoded for POST/PUT.
  """
  @spec rest(String.t(), String.t(), map() | nil) :: {:ok, term()} | {:error, term()}
  def rest(method, path, body \\ nil)

  def rest(method, path, body)
      when method in ["GET", "POST", "PUT", "DELETE", "get", "post", "put", "delete"] and is_binary(path) do
    if String.starts_with?(path, "/rest/") do
      request(method |> String.downcase() |> String.to_existing_atom(), path, body)
    else
      {:error, :jira_path_must_start_with_rest}
    end
  end

  def rest(_method, _path, _body), do: {:error, :jira_invalid_rest_arguments}

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, base_url) when is_map(issue) do
    normalize_issue(issue, nil, base_url)
  end

  @doc false
  @spec match_transition_for_test([map()], String.t()) :: {:ok, String.t()} | {:error, term()}
  def match_transition_for_test(transitions, state_name) do
    match_transition(transitions, state_name)
  end

  @doc false
  @spec branch_name_for_test(String.t() | nil, String.t() | nil) :: String.t() | nil
  def branch_name_for_test(key, title), do: branch_name(key, title)

  @doc false
  @spec parse_datetime_for_test(String.t() | nil) :: DateTime.t() | nil
  def parse_datetime_for_test(raw), do: parse_datetime(raw)

  @doc false
  @spec jql_for_test(String.t(), [String.t()]) :: String.t()
  def jql_for_test(project_key, states), do: project_jql(project_key, states)

  defp validate_tracker_settings(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_jira_api_token}
      is_nil(tracker.email) -> {:error, :missing_jira_email}
      is_nil(tracker.project_slug) -> {:error, :missing_jira_project_key}
      true -> :ok
    end
  end

  defp project_jql(project_key, states) do
    quoted_states = Enum.map_join(states, ", ", &quote_jql_value/1)
    "project = #{quote_jql_value(project_key)} AND status in (#{quoted_states}) ORDER BY created ASC"
  end

  defp keys_jql(keys) do
    quoted_keys = Enum.map_join(keys, ", ", &quote_jql_value/1)
    "key in (#{quoted_keys})"
  end

  defp quote_jql_value(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp do_search(jql, assignee_filter) do
    do_search_page(jql, assignee_filter, nil, [])
  end

  defp do_search_page(jql, assignee_filter, next_page_token, acc_issues) do
    payload =
      %{
        jql: jql,
        maxResults: @issue_page_size,
        fields: String.split(@issue_fields, ",")
      }
      |> maybe_put_page_token(next_page_token)

    with {:ok, body} <- request(:post, "/rest/api/2/search/jql", payload),
         {:ok, issues, page_token} <- decode_search_response(body, assignee_filter) do
      updated_acc = Enum.reverse(issues, acc_issues)

      case page_token do
        token when is_binary(token) and token != "" ->
          do_search_page(jql, assignee_filter, token, updated_acc)

        _ ->
          {:ok, Enum.reverse(updated_acc)}
      end
    end
  end

  defp maybe_put_page_token(payload, token) when is_binary(token) and token != "" do
    Map.put(payload, :nextPageToken, token)
  end

  defp maybe_put_page_token(payload, _token), do: payload

  defp decode_search_response(%{"issues" => issues} = body, assignee_filter) when is_list(issues) do
    normalized =
      issues
      |> Enum.map(&normalize_issue(&1, assignee_filter, base_url()))
      |> Enum.reject(&is_nil/1)

    next_page_token = if body["isLast"] == false, do: body["nextPageToken"], else: nil
    {:ok, normalized, next_page_token}
  end

  defp decode_search_response(_body, _assignee_filter), do: {:error, :jira_unknown_payload}

  defp sort_issues_by_requested_ids(issues, requested_ids) do
    order_index = requested_ids |> Enum.with_index() |> Map.new()
    fallback_index = map_size(order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp resolve_transition_id(issue_key, state_name) do
    case request(:get, "/rest/api/2/issue/#{encode_path(issue_key)}/transitions", nil) do
      {:ok, %{"transitions" => transitions}} when is_list(transitions) ->
        match_transition(transitions, state_name)

      {:ok, _body} ->
        {:error, :jira_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp match_transition(transitions, state_name) do
    wanted = normalize_state_name(state_name)

    transitions
    |> Enum.find(fn transition ->
      target = get_in(transition, ["to", "name"])
      is_binary(target) and normalize_state_name(target) == wanted
    end)
    |> case do
      %{"id" => transition_id} when is_binary(transition_id) -> {:ok, transition_id}
      _ -> {:error, {:transition_not_found, state_name}}
    end
  end

  defp normalize_state_name(name), do: name |> String.trim() |> String.downcase()

  defp request(method, path, payload) do
    with {:ok, headers} <- auth_headers() do
      url = base_url() <> path
      request_fun = Application.get_env(:symphony_elixir, :jira_request_fun, &do_request/4)

      case request_fun.(method, url, headers, payload) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, response} ->
          Logger.error("Jira request failed method=#{method} path=#{path} status=#{response.status} body=#{summarize_error_body(response.body)}")
          {:error, {:jira_api_status, response.status}}

        {:error, reason} ->
          Logger.error("Jira request failed method=#{method} path=#{path}: #{inspect(reason)}")
          {:error, {:jira_api_request, reason}}
      end
    end
  end

  defp do_request(:get, url, headers, _payload) do
    Req.get(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp do_request(:post, url, headers, payload) do
    Req.post(url, headers: headers, json: payload, connect_options: [timeout: 30_000])
  end

  defp do_request(:put, url, headers, payload) do
    Req.put(url, headers: headers, json: payload, connect_options: [timeout: 30_000])
  end

  defp do_request(:delete, url, headers, _payload) do
    Req.delete(url, headers: headers, connect_options: [timeout: 30_000])
  end

  defp auth_headers do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_jira_api_token}

      is_nil(tracker.email) ->
        {:error, :missing_jira_email}

      true ->
        credentials = Base.encode64(tracker.email <> ":" <> tracker.api_key)

        {:ok,
         [
           {"Authorization", "Basic " <> credentials},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp base_url do
    Config.settings!().tracker.endpoint
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp encode_path(segment), do: URI.encode_www_form(segment)

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp normalize_issue(issue, assignee_filter, base_url) when is_map(issue) do
    key = issue["key"]
    fields = issue["fields"] || %{}
    assignee = fields["assignee"]

    if is_binary(key) do
      %Issue{
        id: key,
        identifier: key,
        title: fields["summary"],
        description: normalize_description(fields["description"]),
        priority: priority_rank(get_in(fields, ["priority", "name"])),
        state: get_in(fields, ["status", "name"]),
        branch_name: branch_name(key, fields["summary"]),
        url: base_url <> "/browse/" <> key,
        assignee_id: assignee_field(assignee, "accountId"),
        blocked_by: extract_blockers(fields),
        labels: extract_labels(fields),
        assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
        created_at: parse_datetime(fields["created"]),
        updated_at: parse_datetime(fields["updated"])
      }
    else
      nil
    end
  end

  defp normalize_issue(_issue, _assignee_filter, _base_url), do: nil

  defp normalize_description(description) when is_binary(description) do
    case String.trim(description) do
      "" -> nil
      _ -> description
    end
  end

  defp normalize_description(_description), do: nil

  defp priority_rank(name) when is_binary(name) do
    case String.downcase(String.trim(name)) do
      "highest" -> 1
      "high" -> 2
      "medium" -> 3
      "low" -> 4
      "lowest" -> 4
      _ -> nil
    end
  end

  defp priority_rank(_name), do: nil

  defp branch_name(key, title) when is_binary(key) do
    slug =
      title
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, @max_branch_slug_length)
      |> String.trim("-")

    base = String.downcase(key)

    case slug do
      "" -> base
      slug -> base <> "-" <> slug
    end
  end

  defp branch_name(_key, _title), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case normalize_match_value(assignee["accountId"]) do
      nil -> false
      account_id -> MapSet.member?(match_values, account_id)
    end
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_myself_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_myself_assignee_filter do
    case request(:get, "/rest/api/2/myself", nil) do
      {:ok, %{"accountId" => account_id}} when is_binary(account_id) ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([account_id])}}

      {:ok, _body} ->
        {:error, :missing_jira_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_match_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_match_value(_value), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp extract_labels(_fields), do: []

  defp extract_blockers(%{"issuelinks" => issue_links}) when is_list(issue_links) do
    Enum.flat_map(issue_links, fn
      %{"type" => %{"inward" => inward}, "inwardIssue" => blocker}
      when is_binary(inward) and is_map(blocker) ->
        if String.downcase(String.trim(inward)) == "is blocked by" do
          [
            %{
              id: blocker["key"],
              identifier: blocker["key"],
              state: get_in(blocker, ["fields", "status", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_fields), do: []

  defp parse_datetime(raw) when is_binary(raw) do
    normalized = Regex.replace(~r/([+-]\d{2})(\d{2})$/, raw, "\\1:\\2")

    case DateTime.from_iso8601(normalized) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil
end
