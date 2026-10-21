defmodule To.E2E.Mock do
  use Plug.Router
  import Ecto.Query

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/octet-stream"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  def start_link do
    Agent.start_link(
      fn ->
        %{
          tasks: %{},
          calls: [],
          pushes: [],
          encrypted_pushes: [],
          push_response: nil,
          next_id: 1,
          failures: 0,
          token_error: nil,
          fail_create: false,
          delayed_sync_task: nil
        }
      end,
      name: __MODULE__
    )
  end

  # Reproduce a slow database acknowledgement after Google work has finished.
  def delay_sync_completion(_, _, %{job: %{worker: "To.SyncWorker", args: %{"task_id" => id}}}, _) do
    delay? =
      Agent.get_and_update(__MODULE__, fn state ->
        if state.delayed_sync_task == id,
          do: {true, %{state | delayed_sync_task: nil}},
          else: {false, state}
      end)

    if delay?, do: Process.sleep(2_000)
  end

  def delay_sync_completion(_, _, _, _), do: :ok

  get "/authorize" do
    state = conn.params["state"]

    links =
      for person <- ["Nicole", "Will", "Stranger"], into: "" do
        query = URI.encode_query(%{state: state, code: String.downcase(person)})

        "<p><a href=\"http://127.0.0.1:4002/auth/google/callback?#{query}\">Continue as #{person}</a></p>"
      end

    conn |> put_resp_content_type("text/html") |> send_resp(200, "<h1>Mock Google</h1>" <> links)
  end

  post "/token" do
    person =
      conn.params["code"] ||
        String.replace(conn.params["refresh_token"] || "will", "refresh-", "")

    error = Agent.get_and_update(__MODULE__, &{&1.token_error, %{&1 | token_error: nil}})

    case error do
      "revoked" ->
        json(conn, 400, %{error: "invalid_grant"})

      "unavailable" ->
        json(conn, 503, %{error: "temporarily_unavailable"})

      _ ->
        json(conn, 200, %{access_token: "access-#{person}", refresh_token: "refresh-#{person}"})
    end
  end

  post "/__token-error" do
    Agent.update(__MODULE__, &%{&1 | token_error: conn.params["error"]})
    json(conn, 200, %{})
  end

  post "/__google-connection" do
    user = To.Repo.get_by!(To.Accounts.User, name: conn.params["person"])

    token =
      if conn.params["connected"],
        do:
          Phoenix.Token.encrypt(
            ToWeb.Endpoint,
            "google-refresh",
            "refresh-#{String.downcase(user.name)}"
          )

    user |> Ecto.Changeset.change(google_refresh_token: token) |> To.Repo.update!()
    json(conn, 200, %{})
  end

  get "/profile" do
    person = person(conn)

    json(conn, 200, %{sub: "sub-#{person}", email: "#{person}@example.test", email_verified: true})
  end

  get "/__ready" do
    json(conn, if(Agent.get(__MODULE__, &Map.get(&1, :ready, false)), do: 200, else: 503), %{})
  end

  get "/__state" do
    state = Agent.get(__MODULE__, & &1)

    jobs =
      To.Repo.all(
        from j in Oban.Job, select: %{id: j.id, args: j.args, worker: j.worker, state: j.state}
      )

    json(conn, 200, Map.put(state, :jobs, jobs))
  end

  post "/__google-sync-enabled" do
    enabled = conn.params["enabled"]
    Application.put_env(:to, :google_sync_enabled, enabled)

    if enabled,
      do: Oban.resume_queue(queue: :google_sync),
      else: Oban.pause_queue(queue: :google_sync)

    To.Sync.broadcast_status()
    json(conn, 200, %{})
  end

  post "/__delay-sync-completion" do
    Agent.update(__MODULE__, &%{&1 | delayed_sync_task: conn.params["task_id"]})
    json(conn, 200, %{})
  end

  post "/__fail-create" do
    Agent.update(__MODULE__, &Map.put(&1, :fail_create, true))
    json(conn, 200, %{})
  end

  post "/__retry-sync" do
    task = To.Repo.get_by!(To.Tasks.Task, title: conn.params["title"])

    job =
      To.Repo.one!(
        from j in Oban.Job,
          where:
            j.worker == "To.SyncWorker" and
              fragment("json_extract(?, '$.task_id')", j.args) == ^task.id,
          order_by: [desc: j.id],
          limit: 1
      )

    Oban.retry_job(job.id)
    json(conn, 200, %{})
  end

  post "/__sync-google" do
    user = To.Repo.get_by!(To.Accounts.User, name: conn.params["person"])
    To.Sync.enqueue_for_user(user)
    json(conn, 200, %{})
  end

  post "/__run-reminder" do
    task = To.Repo.get_by!(To.Tasks.Task, title: conn.params["title"])
    user = To.Repo.get!(To.Accounts.User, task.assignee_id)
    subscription = To.Repo.get_by!(To.PushSubscription, user_id: user.id)
    # Simulate the scheduler reaching the notification time; the actual Oban
    # worker still checks current task, subscription, preference and local date.
    args = %{
      task_id: task.id,
      subscription_id: subscription.id,
      due_on: Date.to_iso8601(task.due_on),
      reminder_time: Time.to_iso8601(user.reminder_time),
      time_zone: subscription.time_zone
    }

    {:ok, _} = args |> To.ReminderWorker.new() |> Oban.insert()
    json(conn, 200, %{})
  end

  # Accept only the current encrypted Web Push wire format, so the browser
  # delivery flow catches invalid crypto keys, legacy encoding and broken HTTP.
  # Apple also rejects Topic identifiers that cannot be decoded as base64url.
  post "/__encrypted_push" do
    {:ok, body, conn} = read_body(conn)
    encoding = List.first(get_req_header(conn, "content-encoding"))
    authorization = List.first(get_req_header(conn, "authorization")) || ""
    topic = List.first(get_req_header(conn, "topic")) || ""

    valid_topic =
      byte_size(topic) in 1..32 && match?({:ok, _}, Base.url_decode64(topic, padding: false))

    vapid =
      String.starts_with?(authorization, "vapid t=") && String.contains?(authorization, ",k=")

    valid_body =
      case body do
        <<_salt::binary-size(16), record_size::32, 65, 4, _key::binary-size(64),
          ciphertext::binary>> ->
          record_size >= 4096 && byte_size(ciphertext) > 17

        _ ->
          false
      end

    delivery = %{
      encoding: encoding,
      vapid: vapid,
      encrypted_bytes: byte_size(body),
      valid_encrypted_body: valid_body,
      valid_topic: valid_topic
    }

    Agent.update(
      __MODULE__,
      &Map.update!(&1, :encrypted_pushes, fn pushes -> pushes ++ [delivery] end)
    )

    if encoding == "aes128gcm" && vapid && valid_body && valid_topic do
      status =
        Agent.get_and_update(__MODULE__, &{&1.push_response || 201, %{&1 | push_response: nil}})

      send_resp(conn, status, "")
    else
      json(conn, 400, %{error: "invalid encrypted push request"})
    end
  end

  post "/__push-response" do
    Agent.update(__MODULE__, &%{&1 | push_response: conn.params["status"]})
    json(conn, 200, %{})
  end

  post "/__push" do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, :pushes, fn pushes -> pushes ++ [conn.body_params] end)
    )

    json(conn, 200, %{})
  end

  post "/__fail-next" do
    Agent.update(__MODULE__, &Map.put(&1, :failures, conn.params["count"] || 1))
    json(conn, 200, %{})
  end

  match _ do
    person = person(conn)
    body = conn.body_params

    failed =
      Agent.get_and_update(__MODULE__, fn state ->
        call = %{method: conn.method, path: conn.request_path, person: person, body: body}

        {state.failures > 0,
         %{state | calls: state.calls ++ [call], failures: max(0, state.failures - 1)}}
      end)

    if failed do
      json(conn, 503, %{error: "temporary outage"})
    else
      response =
        Agent.get_and_update(__MODULE__, fn state -> dispatch(conn, person, body, state) end)

      {status, result} = response
      json(conn, status, result)
    end
  end

  defp dispatch(conn, person, body, state) do
    tasks = Map.get(state.tasks, person, %{})

    # The app must use the existing default list; arbitrary lists and list
    # creation must not silently pass this boundary simulation.
    case {conn.method, String.split(URI.decode(conn.request_path), "/", trim: true)} do
      {"GET", ["tasks", "v1", "lists", "@default", "tasks"]} ->
        # Small pages exercise pagination in import and export recovery.
        offset = String.to_integer(conn.params["pageToken"] || "0")

        items =
          tasks
          |> Map.values()
          |> Enum.reject(&(&1["assignmentInfo"] && conn.params["showAssigned"] != "true"))
          |> Enum.reject(
            &(&1["status"] == "completed" && conn.params["showCompleted"] == "false")
          )
          |> Enum.sort_by(& &1["id"])

        body = %{items: Enum.slice(items, offset, 2)}

        body =
          if offset + 2 < length(items),
            do: Map.put(body, :nextPageToken, to_string(offset + 2)),
            else: body

        {{200, body}, state}

      {"POST", ["tasks", "v1", "lists", "@default", "tasks"]} ->
        id = "task-#{state.next_id}"
        task = Map.put(body, "id", id)

        state = %{
          state
          | next_id: state.next_id + 1,
            tasks: Map.put(state.tasks, person, Map.put(tasks, id, task))
        }

        # Google accepts the create while the caller receives a failed response.
        if state.fail_create do
          {{503, %{error: "response lost after creation"}}, %{state | fail_create: false}}
        else
          {{200, task}, state}
        end

      {"PATCH", ["tasks", "v1", "lists", "@default", "tasks", id]} ->
        case Map.fetch(tasks, id) do
          {:ok, task} ->
            task = Map.merge(task, body)

            {{200, task},
             %{state | tasks: Map.put(state.tasks, person, Map.put(tasks, id, task))}}

          :error ->
            {{404, %{error: "task not found"}}, state}
        end

      {"DELETE", ["tasks", "v1", "lists", "@default", "tasks", id]} ->
        {{200, %{}}, %{state | tasks: Map.put(state.tasks, person, Map.delete(tasks, id))}}

      _ ->
        {{404, %{error: "unhandled mock request"}}, state}
    end
  end

  defp person(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> to_string()
    |> String.replace("Bearer access-", "")
  end

  defp json(conn, status, value),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(value))
end
