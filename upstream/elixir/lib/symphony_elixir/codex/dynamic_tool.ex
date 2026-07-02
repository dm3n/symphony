defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Jira
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @jira_request_tool "jira_request"
  @jira_request_description """
  Execute a raw Jira Cloud REST API request using Symphony's configured auth.
  """
  @jira_request_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PUT", "DELETE"],
        "description" => "HTTP method. Defaults to GET."
      },
      "path" => %{
        "type" => "string",
        "description" => "Jira REST path starting with /rest/, e.g. /rest/api/2/issue/AD-1/comment. May include a query string."
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON body for POST/PUT requests.",
        "additionalProperties" => true
      }
    }
  }
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @jira_request_tool ->
        execute_jira_request(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case tracker_kind() do
      "jira" ->
        [
          %{
            "name" => @jira_request_tool,
            "description" => @jira_request_description,
            "inputSchema" => @jira_request_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp tracker_kind do
    Config.settings!().tracker.kind
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp execute_jira_request(arguments, opts) do
    jira_client = Keyword.get(opts, :jira_client, &Jira.Client.rest/3)

    with {:ok, method, path, body} <- normalize_jira_request_arguments(arguments),
         {:ok, response} <- jira_client.(method, path, body) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(jira_tool_error_payload(reason))
    end
  end

  defp normalize_jira_request_arguments(arguments) when is_map(arguments) do
    path = Map.get(arguments, "path") || Map.get(arguments, :path)
    method = Map.get(arguments, "method") || Map.get(arguments, :method) || "GET"
    body = Map.get(arguments, "body") || Map.get(arguments, :body)

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :missing_jira_path}

      not is_binary(method) ->
        {:error, :invalid_jira_method}

      not (is_map(body) or is_nil(body)) ->
        {:error, :invalid_jira_body}

      true ->
        {:ok, String.upcase(method), String.trim(path), body}
    end
  end

  defp normalize_jira_request_arguments(_arguments), do: {:error, :missing_jira_path}

  defp jira_tool_error_payload(:missing_jira_path) do
    %{"error" => %{"message" => "`jira_request` requires a non-empty `path` string starting with /rest/."}}
  end

  defp jira_tool_error_payload(:invalid_jira_method) do
    %{"error" => %{"message" => "`jira_request.method` must be one of GET, POST, PUT, DELETE."}}
  end

  defp jira_tool_error_payload(:invalid_jira_body) do
    %{"error" => %{"message" => "`jira_request.body` must be a JSON object when provided."}}
  end

  defp jira_tool_error_payload(:jira_path_must_start_with_rest) do
    %{"error" => %{"message" => "`jira_request.path` must start with /rest/."}}
  end

  defp jira_tool_error_payload(:missing_jira_api_token) do
    %{"error" => %{"message" => "Symphony is missing Jira auth. Set `tracker.api_key` in `WORKFLOW.md` or export `JIRA_API_TOKEN`."}}
  end

  defp jira_tool_error_payload(:missing_jira_email) do
    %{"error" => %{"message" => "Symphony is missing the Jira account email. Set `tracker.email` in `WORKFLOW.md` or export `JIRA_EMAIL`."}}
  end

  defp jira_tool_error_payload({:jira_api_status, status}) do
    %{"error" => %{"message" => "Jira REST request failed with HTTP #{status}.", "status" => status}}
  end

  defp jira_tool_error_payload({:jira_api_request, reason}) do
    %{"error" => %{"message" => "Jira REST request failed before receiving a successful response.", "reason" => inspect(reason)}}
  end

  defp jira_tool_error_payload(reason) do
    %{"error" => %{"message" => "Jira REST tool execution failed.", "reason" => inspect(reason)}}
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
