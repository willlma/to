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
          next_id: 1,
          failures: 0,
          fail_create: false
        }
      end,
      name: __MODULE__
    )
  end

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

    json(conn, 200, %{access_token: "access-#{person}", refresh_token: "refresh-#{person}"})
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
  post "/__encrypted_push" do
    {:ok, body, conn} = read_body(conn)
    encoding = List.first(get_req_header(conn, "content-encoding"))
    authorization = List.first(get_req_header(conn, "authorization")) || ""

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
      valid_encrypted_body: valid_body
    }

    Agent.update(
      __MODULE__,
      &Map.update!(&1, :encrypted_pushes, fn pushes -> pushes ++ [delivery] end)
    )

    if encoding == "aes128gcm" && vapid && valid_body do
      send_resp(conn, 201, "")
    else
      json(conn, 400, %{error: "invalid encrypted push request"})
    end
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
    list_id = "list-#{person}"
    tasks = Map.get(state.tasks, person, %{})

    case {conn.method, String.split(conn.request_path, "/", trim: true)} do
      {"GET", ["tasks", "v1", "users", "@me", "lists"]} ->
        {{200, %{items: [%{id: list_id, title: "To"}]}}, state}

      {"GET", ["tasks", "v1", "users", "@me", "lists", _]} ->
        {{200, %{id: list_id, title: "To"}}, state}

      {"GET", ["tasks", "v1", "lists", _, "tasks"]} ->
        {{200, %{items: Map.values(tasks)}}, state}

      {"POST", ["tasks", "v1", "lists", _, "tasks"]} ->
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

      {"PATCH", ["tasks", "v1", "lists", _, "tasks", id]} ->
        task = Map.merge(Map.get(tasks, id, %{"id" => id}), body)
        {{200, task}, %{state | tasks: Map.put(state.tasks, person, Map.put(tasks, id, task))}}

      {"DELETE", ["tasks", "v1", "lists", _, "tasks", id]} ->
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
