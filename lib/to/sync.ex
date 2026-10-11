defmodule To.Sync do
  import Ecto.Query
  alias To.{Accounts, GoogleExport, Repo, SyncWorker}
  alias To.Accounts.{Google, User}
  alias To.Tasks.Task

  # The caller inserts this job in the same transaction as the task change.
  def enqueue(task), do: SyncWorker.new(%{task_id: task.id})

  def enqueue_for_user(user) do
    Repo.all(
      from(t in Task,
        left_join: e in GoogleExport,
        on: e.task_id == t.id,
        where: t.assignee_id == ^user.id oapr e.user_id == ^user.id,
        distinct: true
      )
    )
    |> Enum.each(fn task -> task |> enqueue() |> Oban.insert() end)

    :ok
  end

  def status(task) do
    cond do
      not eligible?(task) ->
        if Repo.exists?(from(e in GoogleExport, where: e.task_id == ^task.id)),
          do: job_status(task.id),
          else: :not_required

      not connected?(Accounts.get_user(task.assignee_id)) ->
        :not_connected

      true ->
        case Repo.get_by(GoogleExport, task_id: task.id, user_id: task.assignee_id) do
          %GoogleExport{payload_hash: hash} when is_binary(hash) ->
            if hash == payload_hash(task), do: :synced, else: job_status(task.id)

          _ ->
            job_status(task.id)
        end
    end
  end

  def run(task_id) do
    task = Repo.get(Task, task_id)
    exports = Repo.all(from(e in GoogleExport, where: e.task_id == ^task_id))

    result =
      with :ok <- remove_stale_exports(task, exports) do
        if eligible?(task), do: export(task), else: :ok
      end

    if task do
      args = [To.PubSub, "tasks:#{task.list_id}", {:tasks_changed, task.list_id}]
      apply(Phoenix.PubSub, :broadcast, args)

      # Oban records retryable/discarded after perform returns; refresh that status afterward.
      if match?({:error, _}, result) do
        :timer.apply_after(1_000, Phoenix.PubSub, :broadcast, args)
      end
    end

    result
  end

  defp eligible?(nil), do: false

  defp eligible?(task),
    do: task.assignee_id != nil && task.due_on != nil && task.deleted_at == nil

  defp connected?(%User{google_refresh_token: token}), do: is_binary(token) && token != ""
  defp connected?(_), do: false

  defp job_status(task_id) do
    args = %{"task_id" => task_id}

    state =
      Repo.one(
        from(j in Oban.Job,
          where: j.worker == "To.SyncWorker" and j.args == ^args,
          order_by: [desc: j.id],
          limit: 1,
          select: j.state
        )
      )

    if state in ["retryable", "discarded"], do: :error, else: :pending
  end

  defp remove_stale_exports(task, exports) do
    exports
    |> Enum.reject(fn e -> eligible?(task) && e.user_id == task.assignee_id end)
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

    if connected?(user) do
      with {:ok, token} <- Google.refresh_access_token(user) do
        case Repo.get_by(GoogleExport, task_id: task.id, user_id: user.id) do
          nil -> create_export(task, user, token)
          existing -> update_export(task, user, token, existing)
        end
      end
    else
      # OAuth completion queues these again. Missing credentials must not block local work.
      :ok
    end
  end

  defp update_export(task, user, token, existing) do
    case request(
           :patch,
           task_path(existing.google_list_id, existing.google_task_id),
           token,
           payload(task)
         ) do
      {:ok, _} ->
        save_export(existing, task, existing.google_list_id, existing.google_task_id)

      {:error, {:google_status, 404}} ->
        with {:ok, _} <- Repo.delete(existing), do: create_export(task, user, token)

      error ->
        error
    end
  end

  defp create_export(task, user, token) do
    with {:ok, list_id} <- task_list(user, token),
         {:ok, tasks} <-
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

  defp task_list(user, token) do
    case user.google_task_list_id do
      nil ->
        find_task_list(user, token)

      id ->
        case request(:get, "/users/@me/lists/#{segment(id)}", token) do
          {:ok, _} -> {:ok, id}
          {:error, {:google_status, 404}} -> find_task_list(user, token)
          error -> error
        end
    end
  end

  defp find_task_list(user, token) do
    with {:ok, lists} <- all_items("/users/@me/lists", token, %{maxResults: 1000}),
         {:ok, list} <- existing_or_create_list(lists, token),
         {:ok, _} <- Repo.update(User.changeset(user, %{google_task_list_id: list["id"]})) do
      {:ok, list["id"]}
    end
  end

  defp existing_or_create_list(lists, token) do
    case Enum.find(lists, &(&1["title"] == "To")) do
      nil -> request(:post, "/users/@me/lists", token, %{title: "To"})
      list -> {:ok, list}
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
      due: Date.to_iso8601(task.due_on) <> "T00:00:00Z",
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
