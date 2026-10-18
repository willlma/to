defmodule To.Tasks do
  import Ecto.Query
  alias Ecto.Changeset
  alias To.{Accounts, Repo}
  alias To.Tasks.{List, Task}

  def list_lists do
    lists =
      Repo.all(
        from(l in List, where: is_nil(l.deleted_at), order_by: [asc: l.inserted_at, asc: l.id])
      )

    if lists == [] do
      %List{}
      |> List.changeset(%{name: "To do"})
      |> Repo.insert(on_conflict: :nothing)

      list_lists()
    else
      lists
    end
  end

  def create_list(attrs) do
    result = %List{} |> List.changeset(attrs) |> Repo.insert()

    if match?({:ok, _}, result), do: Phoenix.PubSub.broadcast(To.PubSub, "lists", :lists_changed)
    result
  end

  def get_list(id), do: Repo.one(from(l in List, where: l.id == ^id and is_nil(l.deleted_at)))
  def get_list!(id), do: Repo.one!(from(l in List, where: l.id == ^id and is_nil(l.deleted_at)))

  def delete_list(actor, %List{} = list) do
    result =
      Repo.transaction(fn ->
        actor_id!(actor)

        if Repo.aggregate(from(l in List, where: is_nil(l.deleted_at)), :count) <= 1,
          do: Repo.rollback(:last_list)

        Repo.all(from(t in Task, where: t.list_id == ^list.id and is_nil(t.deleted_at)))
        |> Enum.each(fn task ->
          case delete_task(actor, task) do
            {:ok, _} -> :ok
            {:error, error} -> Repo.rollback(error)
          end
        end)

        list |> Changeset.change(deleted_at: now()) |> Repo.update!()
      end)

    if match?({:ok, _}, result), do: Phoenix.PubSub.broadcast(To.PubSub, "lists", :lists_changed)
    result
  end

  def list_tasks(list_id) do
    future_cutoff = Date.add(Date.utc_today(), 30)

    Repo.all(
      from(t in Task,
        where: t.list_id == ^list_id and is_nil(t.deleted_at),
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? IS NULL THEN 1 WHEN ? > ? THEN 2 ELSE 0 END",
              t.due_on,
              t.due_on,
              type(^future_cutoff, :date)
            ),
          asc: t.due_on,
          asc: t.created_at,
          asc: t.id
        ],
        preload: [:assignee, :created_by, :updated_by]
      )
    )
  end

  def get_task!(list_id, id) do
    Repo.one!(
      from(t in Task, where: t.list_id == ^list_id and t.id == ^id and is_nil(t.deleted_at))
    )
  end

  def change_task(task, attrs \\ %{}), do: Task.changeset(task, attrs)

  def create_task(actor, list_id, attrs) do
    actor_id = actor_id!(actor)
    list = get_list!(list_id)

    %Task{list_id: list.id, created_by_id: actor_id, updated_by_id: actor_id}
    |> Task.changeset(attrs)
    |> validate_assignee()
    |> write(:insert)
  end

  def update_task(actor, %Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Changeset.put_change(:updated_by_id, actor_id!(actor))
    |> validate_assignee()
    |> write(:update)
  end

  def toggle_task(actor, %Task{} = task) do
    task
    |> Changeset.change(completed_at: if(task.completed_at, do: nil, else: now()))
    |> Changeset.put_change(:updated_by_id, actor_id!(actor))
    |> write(:update)
  end

  def delete_task(actor, %Task{} = task) do
    task
    |> Changeset.change(deleted_at: now(), updated_by_id: actor_id!(actor))
    |> write(:update)
  end

  def rename_group(actor, list_id, old_name, new_name, opts \\ []) do
    actor_id = actor_id!(actor)
    old_name = Task.normalize_group(old_name)
    new_name = Task.normalize_group(new_name)

    result =
      Repo.transaction(fn ->
        if new_name && String.length(new_name) > 100, do: Repo.rollback(:name_too_long)
        query = from(t in Task, where: t.list_id == ^list_id and is_nil(t.deleted_at))

        query =
          if old_name,
            do: from(t in query, where: t.nested_under == ^old_name),
            else: from(t in query, where: is_nil(t.nested_under))

        if old_name == new_name || !Repo.exists?(query) do
          0
        else
          if new_name && !Keyword.get(opts, :merge, false) &&
               Repo.exists?(
                 from(t in Task,
                   where:
                     t.list_id == ^list_id and t.nested_under == ^new_name and
                       is_nil(t.deleted_at)
                 )
               ) do
            Repo.rollback(:merge_required)
          end

          {count, _} =
            Repo.update_all(query,
              set: [nested_under: new_name, updated_by_id: actor_id, updated_at: now()]
            )

          count
        end
      end)

    if match?({:ok, _}, result), do: broadcast(list_id)
    result
  end

  def subscribe(list_id), do: Phoenix.PubSub.subscribe(To.PubSub, "tasks:#{list_id}")
  def subscribe_lists, do: Phoenix.PubSub.subscribe(To.PubSub, "lists")

  defp write(changeset, operation) do
    result =
      Repo.transaction(fn ->
        task =
          case apply(Repo, operation, [changeset]) do
            {:ok, task} -> task
            {:error, error} -> Repo.rollback(error)
          end

        case task |> To.Sync.enqueue() |> Oban.insert() do
          {:ok, _} -> :ok
          {:error, error} -> Repo.rollback(error)
        end

        case To.Reminders.schedule(task) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, error} -> Repo.rollback(error)
        end

        Repo.preload(task, [:assignee, :created_by, :updated_by], force: true)
      end)

    case result do
      {:ok, task} -> broadcast(task.list_id)
      _ -> :ok
    end

    result
  end

  defp validate_assignee(changeset) do
    assignee_id = Changeset.get_field(changeset, :assignee_id)

    if is_nil(assignee_id) || assignee_id in Enum.map(Accounts.list_users(), & &1.id) do
      changeset
    else
      Changeset.add_error(changeset, :assignee_id, "must be Nicole or Will")
    end
  end

  defp actor_id!(%Accounts.User{id: id}), do: actor_id!(id)

  defp actor_id!(id) do
    case Accounts.get_user(id) do
      %Accounts.User{id: id, name: name} when name in ["Nicole", "Will"] -> id
      _ -> raise ArgumentError, "a household user is required"
    end
  end

  defp broadcast(list_id) do
    Phoenix.PubSub.broadcast(To.PubSub, "tasks:#{list_id}", {:tasks_changed, list_id})
    To.Sync.broadcast_status()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
