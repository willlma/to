defmodule To.Sync do
  import Ecto.Query
  alias To.{Accounts, GoogleExport, Repo, SyncWorker}
  alias To.Accounts.{Google, User}
  alias To.Tasks.Task

  def enabled?, do: Application.get_env(:to, :google_sync_enabled, true)

  def needed?(changeset, task) do
    fields = [:title, :description, :due_on, :assignee_id, :completed_at, :deleted_at]

    enabled?() && Enum.any?(fields, &Map.has_key?(changeset.changes, &1)) &&
      (Enum.any?([changeset.data, task], fn candidate ->
         eligible?(candidate) && connected?(Accounts.get_user(candidate.assignee_id))
       end) || Repo.exists?(from(e in GoogleExport, where: e.task_id == ^task.id)))
  end

  # The caller inserts this job in the same transaction as the task change.
  def enqueue(task), do: SyncWorker.new(%{task_id: task.id})

  def import_tasks(user) do
    list_id = hd(To.Tasks.list_lists()).id

    with {:ok, token} <- Google.refresh_access_token(user),
         {:ok, items} <-
           all_items("/lists/#{segment("@default")}/tasks", token, %{
             showCompleted: false,
             showHidden: false,
             showAssigned: true,
             maxResults: 100
           }) do
      result =
        Repo.transaction(fn ->
          list = To.Tasks.get_list!(list_id)

          Enum.reduce(import_items(items), %{imported: 0, skipped: 0, invalid: 0}, fn remote,
                                                                                      counts ->
            outcome = import_task(user, list.id, remote)
            Map.update!(counts, outcome, &(&1 + 1))
          end)
        end)

      if match?({:ok, _}, result) do
        Phoenix.PubSub.broadcast(To.PubSub, "tasks:#{list_id}", {:tasks_changed, list_id})
      end

      result
    end
  end

  defp import_items(items) do
    items = Enum.reject(items, &(&1["deleted"] == true || &1["status"] == "completed"))
    ids = MapSet.new(items, & &1["id"])
    children = Enum.group_by(items, & &1["parent"])

    items
    |> Enum.reject(&MapSet.member?(ids, &1["parent"]))
    |> Enum.map(fn remote ->
      bullets =
        Map.get(children, remote["id"], [])
        |> Enum.sort_by(& &1["position"])
        |> Enum.map_join("\n", fn child ->
          notes =
            if child["notes"] not in [nil, ""],
              do: "\n  " <> String.replace(child["notes"], "\n", "\n  "),
              else: ""

          "- " <> (child["title"] || "") <> notes
        end)

      notes = Enum.reject([remote["notes"], bullets], &(&1 in [nil, ""])) |> Enum.join("\n\n")
      Map.put(remote, "notes", notes)
    end)
  end

  defp import_task(user, list_id, %{"id" => id} = remote) when is_binary(id) and id != "" do
    imported =
      Repo.exists?(
        from(t in Task,
          where: t.google_import_user_id == ^user.id and t.google_import_id == ^id
        )
      )

    exported =
      Repo.exists?(
        from(e in GoogleExport,
          where:
            e.user_id == ^user.id and e.google_task_id == ^id and e.google_list_id == "@default"
        )
      )

    if imported || exported do
      :skipped
    else
      attrs = %{
        title: remote["title"],
        description: remote["notes"],
        assignee_id: user.id,
        due_on: if(remote["due"], do: String.slice(remote["due"], 0, 10))
      }

      changeset =
        %Task{list_id: list_id, created_by_id: user.id, updated_by_id: user.id}
        |> Task.changeset(attrs)
        |> Ecto.Changeset.change(
          google_import_user_id: user.id,
          google_import_id: id
        )

      case Repo.insert(changeset) do
        {:ok, task} ->
          case save_export(%GoogleExport{}, task, "@default", id) do
            :ok -> :ok
            {:error, error} -> Repo.rollback(error)
          end

          case To.Reminders.schedule(task) do
            :ok -> :ok
            {:error, error} -> Repo.rollback(error)
          end

          :imported

        {:error, _} ->
          :invalid
      end
    end
  end

  defp import_task(_, _, _), do: :invalid

  def enqueue_for_user(user) do
    if enabled?() do
      Repo.all(
        from(t in Task,
          left_join: e in GoogleExport,
          on: e.task_id == t.id,
          where:
            (t.assignee_id == ^user.id and not is_nil(t.due_on) and is_nil(t.deleted_at)) or
              e.user_id == ^user.id,
          distinct: true
        )
      )
      |> Enum.each(fn task -> task |> enqueue() |> Oban.insert() end)

      broadcast_status()
    end

    :ok
  end

  def status, do: if(enabled?(), do: job_status(), else: :idle)

  defp job_status do
    latest =
      from(j in Oban.Job,
        where: j.worker == "To.SyncWorker",
        group_by: j.args,
        select: %{id: max(j.id)}
      )

    jobs =
      Repo.all(
        from(j in Oban.Job,
          join: latest in subquery(latest),
          on: j.id == latest.id,
          select: %{state: j.state, errors: j.errors}
        )
      )

    cond do
      Enum.any?(jobs, &(&1.state == "discarded")) ->
        :error

      Enum.any?(jobs, &(&1.state != "completed" && &1.state != "cancelled" && &1.errors != [])) ->
        :retrying

      true ->
        :idle
    end
  end

  def subscribe, do: Phoenix.PubSub.subscribe(To.PubSub, "google-sync")

  def broadcast_status,
    do: Phoenix.PubSub.broadcast(To.PubSub, "google-sync", {:sync_status, status()})

  # Oban emits these events after recording completion or failure in the database.
  def handle_job_event(_, _, %{job: %{worker: "To.SyncWorker"}}, _), do: broadcast_status()
  def handle_job_event(_, _, _, _), do: :ok

  def run(task_id) do
    if enabled?() do
      task = Repo.get(Task, task_id)
      exports = Repo.all(from(e in GoogleExport, where: e.task_id == ^task_id))

      with :ok <- remove_stale_exports(task, exports) do
        if eligible?(task), do: export(task), else: :ok
      end
    else
      {:cancel, :google_sync_disabled}
    end
  end

  defp eligible?(nil), do: false

  defp eligible?(task),
    do: task.assignee_id != nil && task.due_on != nil && task.deleted_at == nil

  defp connected?(%User{google_refresh_token: token}), do: is_binary(token) && token != ""
  defp connected?(_), do: false

  defp remove_stale_exports(task, exports) do
    exports
    |> Enum.reject(fn e ->
      # An undated imported original must survive reconnecting, even though
      # ordinary undated tasks are not exported.
      imported_original =
        task && !task.deleted_at && task.google_import_user_id == e.user_id &&
          task.google_import_id == e.google_task_id

      task && !task.deleted_at && (eligible?(task) || imported_original) &&
        e.user_id == task.assignee_id && e.google_list_id == "@default"
    end)
    |> Enum.reduce_while(:ok, fn e, :ok ->
      with user when not is_nil(user) <- Accounts.get_user(e.user_id),
           {:ok, token} <- Google.refresh_access_token(user),
           {:ok, _} <- request(:delete, task_path(e.google_list_id, e.google_task_id), token),
           {:ok, _} <- Repo.delete(e) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :google_cleanup_failed}}
      end
    end)
  end

  defp export(task) do
    user = Accounts.get_user(task.assignee_id)
    existing = Repo.get_by(GoogleExport, task_id: task.id, user_id: user.id)

    cond do
      !connected?(user) ->
        # OAuth completion queues these again when credentials are available.
        :ok

      existing && existing.payload_hash == payload_hash(task) ->
        :ok

      true ->
        with {:ok, token} <- Google.refresh_access_token(user) do
          if existing,
            do: update_export(task, token, existing),
            else: create_export(task, token)
        end
    end
  end

  defp update_export(task, token, existing) do
    case request(
           :patch,
           task_path(existing.google_list_id, existing.google_task_id),
           token,
           payload(task)
         ) do
      {:ok, _} ->
        save_export(existing, task, existing.google_list_id, existing.google_task_id)

      {:error, {:google_status, 404}} ->
        with {:ok, _} <- Repo.delete(existing), do: create_export(task, token)

      error ->
        error
    end
  end

  defp create_export(task, token) do
    list_id = "@default"

    with {:ok, tasks} <-
           all_items("/lists/#{segment(list_id)}/tasks", token, %{
             showCompleted: true,
             showHidden: true,
             maxResults: 100
           }),
         {:ok, remote} <- find_or_create(task, list_id, tasks, token),
         {:ok, _} <- request(:patch, task_path(list_id, remote["id"]), token, payload(task)) do
      save_export(%GoogleExport{}, task, list_id, remote["id"])
    end
  end

  defp find_or_create(task, list_id, tasks, token) do
    case Enum.find(tasks, &String.ends_with?(&1["notes"] || "", marker(task))) do
      nil -> request(:post, "/lists/#{segment(list_id)}/tasks", token, payload(task))
      existing -> {:ok, existing}
    end
  end

  defp all_items(path, token, params, items \\ []) do
    with {:ok, body} <- request(:get, path, token, nil, params) do
      items = items ++ (body["items"] || [])

      case body["nextPageToken"] do
        nil -> {:ok, items}
        page -> all_items(path, token, Map.put(params, :pageToken, page), items)
      end
    end
  end

  defp save_export(existing, task, list_id, remote_id) do
    attrs = %{
      task_id: task.id,
      user_id: task.assignee_id,
      google_task_id: remote_id,
      google_list_id: list_id,
      payload_hash: payload_hash(task),
      synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case existing |> GoogleExport.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :export_save_failed}
    end
  end

  defp payload(task) do
    %{
      title: task.title,
      notes: (task.description || "") <> marker(task),
      due: if(task.due_on, do: Date.to_iso8601(task.due_on) <> "T00:00:00Z"),
      status: if(task.completed_at, do: "completed", else: "needsAction"),
      completed: if(task.completed_at, do: DateTime.to_iso8601(task.completed_at), else: nil)
    }
  end

  defp payload_hash(task),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(payload(task))) |> Base.encode16(case: :lower)

  defp marker(task), do: "\n\n[to task #{task.id}]"
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp task_path(list_id, task_id), do: "/lists/#{segment(list_id)}/tasks/#{segment(task_id)}"

  # Never include response bodies, tokens, or request structs in job errors.
  defp request(method, path, token, body \\ nil, params \\ %{}) do
    opts = [
      method: method,
      url: api_base() <> path,
      auth: {:bearer, token},
      params: params,
      retry: false,
      receive_timeout: 15_000
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} when method == :delete and status in [404, 410] -> {:ok, %{}}
      {:ok, %{status: 401}} -> {:error, :google_reconnect_required}
      {:ok, %{status: status}} -> {:error, {:google_status, status}}
      {:error, _} -> {:error, :google_unavailable}
    end
  end

  if Mix.env() == :test do
    defp api_base,
      do: Application.get_env(:to, :google_tasks_api, "https://tasks.googleapis.com/tasks/v1")
  else
    defp api_base, do: "https://tasks.googleapis.com/tasks/v1"
  end
end
