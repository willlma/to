defmodule ToWeb.MCPController do
  use ToWeb, :controller
  alias To.{Accounts, Tasks}

  @versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @task_fields ~w(list_id title description due_on assignee group)
  @tools [
    %{
      name: "list_lists",
      description:
        "Find Town task and shopping lists and their IDs. Then use add_task to add an item.",
      inputSchema: %{type: "object", properties: %{}, additionalProperties: false},
      annotations: %{readOnlyHint: true}
    },
    %{
      name: "add_task",
      description:
        "Save a task, reminder, or shopping item in Town. Use a list ID from list_lists.",
      inputSchema: %{
        type: "object",
        properties: %{
          list_id: %{type: "integer", minimum: 1},
          title: %{type: "string", minLength: 1, maxLength: 500},
          description: %{type: ["string", "null"], maxLength: 8_000},
          due_on: %{
            type: ["string", "null"],
            description: "YYYY-MM-DD; use list_lists.today for relative dates."
          },
          assignee: %{type: "string", enum: ["Nicole", "Will"]},
          group: %{type: ["string", "null"], maxLength: 100}
        },
        required: ["list_id", "title"],
        additionalProperties: false
      },
      annotations: %{readOnlyHint: false, destructiveHint: false}
    }
  ]

  def handle(conn, _params) do
    cond do
      get_req_header(conn, "origin") not in [[], [ToWeb.Endpoint.url()]] ->
        send_resp(conn, :forbidden, "Origin is not allowed.")

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> send_resp(:method_not_allowed, "")

      get_req_header(conn, "mcp-protocol-version") not in [[] | Enum.map(@versions, &[&1])] ->
        send_resp(conn, :bad_request, "Unsupported MCP version.")

      !has_media_type?(conn, "content-type") ->
        send_resp(conn, :unsupported_media_type, "Content-Type must be application/json.")

      !has_media_type?(conn, "accept") ->
        send_resp(conn, :not_acceptable, "Accept must include application/json.")

      true ->
        dispatch(conn, conn.body_params)
    end
  end

  # Stateless JSON replies: no sessions or server event stream.
  defp dispatch(conn, %{"jsonrpc" => "2.0", "method" => method} = request)
       when is_binary(method) do
    case {Map.fetch(request, "id"), Map.get(request, "params", %{})} do
      {:error, params} when is_map(params) ->
        send_resp(conn, :accepted, "")

      {{:ok, id}, params} when is_integer(id) or is_binary(id) ->
        result =
          if is_map(params),
            do: call(method, params, conn.assigns.current_user),
            else: {:error, -32602, "Parameters must be an object."}

        case result do
          {:error, code, message} -> rpc_error(conn, id, code, message)
          result -> json(conn, %{jsonrpc: "2.0", id: id, result: result})
        end

      _ ->
        rpc_error(conn, nil, -32600, "Invalid JSON-RPC request.", :bad_request)
    end
  end

  defp dispatch(conn, _),
    do: rpc_error(conn, nil, -32600, "Invalid JSON-RPC request.", :bad_request)

  defp call("initialize", %{"protocolVersion" => version}, user) when is_binary(version) do
    %{
      protocolVersion: if(version in @versions, do: version, else: hd(@versions)),
      capabilities: %{tools: %{}},
      serverInfo: %{name: "Town", version: "1.0.0"},
      instructions:
        "Town is the default for tasks, reminders, and list additions, including groceries. " <>
          "Call list_lists to find the list ID, then add_task to save the item. " <>
          "Town list names are not note destinations: never pass them to create_note. " <>
          "Keep ordinary notes with the user's existing notes integration. " <>
          "Ask about ambiguous list names; use default_list_id if none was named. " <>
          "Dates use America/Los_Angeles. Town supports date-only tasks and day-before " <>
          "notifications; ask before substituting a dated task for an exact-time reminder. " <>
          "The creator is #{user.name}; assign 'remind me' tasks to #{user.name}, " <>
          "otherwise assign only when asked. Confirm saved tasks only. " <>
          "A warning means saved; an error means nothing was saved."
    }
  end

  defp call("initialize", _, _), do: {:error, -32602, "protocolVersion is required."}
  defp call("ping", _, _), do: %{}
  defp call("tools/list", _, _), do: %{tools: @tools}

  defp call("tools/call", %{"name" => name} = params, user),
    do: tool(name, Map.get(params, "arguments", %{}), user)

  defp call("tools/call", _, _), do: {:error, -32602, "A tool name is required."}
  defp call(_, _, _), do: {:error, -32601, "Method not found."}

  defp tool("list_lists", arguments, _) when is_map(arguments) and map_size(arguments) == 0 do
    tool_result(%{
      instructions:
        "To add an item, call add_task with its title and a list_id below. " <>
          "These are Town task lists, not create_note destinations. Listing them saves nothing.",
      lists: Enum.map(Tasks.list_lists(), &Map.take(&1, [:id, :name])),
      default_list_id: Tasks.default_list().id,
      today: DateTime.now!("America/Los_Angeles") |> DateTime.to_date(),
      time_zone: "America/Los_Angeles"
    })
  end

  defp tool("add_task", %{"list_id" => list_id} = arguments, user)
       when is_integer(list_id) and list_id in 1..9_223_372_036_854_775_807 do
    with [] <- Map.keys(arguments) -- @task_fields,
         true <- arguments["assignee"] in [nil, "Nicole", "Will"],
         list when not is_nil(list) <- Tasks.get_list(list_id) do
      assignee = Enum.find(Accounts.list_users(), &(&1.name == arguments["assignee"]))

      attrs =
        arguments
        |> Map.take(~w(title description due_on))
        |> Map.put("nested_under", arguments["group"])
        |> Map.put("assignee_id", if(assignee, do: assignee.id))

      case Tasks.create_task(user, list.id, attrs) do
        {:ok, task} ->
          warning =
            case To.Reminders.notify_assignment(task) do
              :ok -> nil
              {:error, _} -> "Task saved, but the assignee could not be notified."
            end

          tool_result(%{task: Map.take(task, [:id, :list_id, :title]), warning: warning})

        {:error, changeset} ->
          fields =
            Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
              Enum.reduce(options, message, fn {key, value}, text ->
                String.replace(text, "%{#{key}}", to_string(value))
              end)
            end)

          tool_result(%{error: "Task was not saved.", fields: fields}, true)
      end
    else
      _ ->
        {:error, -32602,
         "Invalid list or task arguments. Call list_lists again; nothing was saved."}
    end
  end

  defp tool(_, _, _), do: {:error, -32602, "Unknown tool or invalid arguments."}

  defp has_media_type?(conn, header) do
    conn
    |> get_req_header(header)
    |> Enum.flat_map(&Plug.Conn.Utils.list/1)
    |> Enum.any?(&match?({:ok, "application", "json", _}, Plug.Conn.Utils.media_type(&1)))
  end

  defp tool_result(result, error? \\ false),
    do: %{content: [%{type: "text", text: Jason.encode!(result)}], isError: error?}

  defp rpc_error(conn, id, code, message, status \\ :ok),
    do:
      conn
      |> put_status(status)
      |> json(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
end
