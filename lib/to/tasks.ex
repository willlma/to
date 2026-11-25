defmodule To.Tasks do
  import Ecto.Query
  alias Ecto.Changeset
  alias To.{Accounts, Repo}
  alias To.Tasks.{List, Task}

  def list_lists do
    lists =
      Repo.all(
        from(l in List, where: is_nil(l.deleted_at), order_by: [asc: l.position, asc: l.id])
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
    result =
      Repo.transaction(fn ->
        position =
          (Repo.aggregate(from(l in List, where: is_nil(l.deleted_at)), :max, :position) || -1) +
            1

        case %List{position: position} |> List.changeset(attrs) |> Repo.insert() do
          {:ok, list} -> list
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    if match?({:ok, _}, result), do: Phoenix.PubSub.broadcast(To.PubSub, "lists", :lists_changed)
    result
  end

  # The Google import destination stays the oldest list, independently of tab order.
  def default_list do
    Repo.one(
      from(l in List,
        where: is_nil(l.deleted_at),
        order_by: [asc: l.inserted_at, asc: l.id],
        limit: 1
      )
    ) ||
      hd(list_lists())
  end

  def reorder_lists(actor, ids) when is_list(ids) do
    result =
      Repo.transaction(fn ->
        actor_id!(actor)
        expected = Enum.map(list_lists(), &to_string(&1.id))

        if Enum.sort(ids) != Enum.sort(expected), do: Repo.rollback(:stale_order)
        save_positions(List, ids)
      end)

    if match?({:ok, _}, result), do: Phoenix.PubSub.broadcast(To.PubSub, "lists", :lists_changed)
    result
  end

  def reorder_lists(_actor, _ids), do: {:error, :invalid_order}

  def change_list(list, attrs \\ %{}), do: List.changeset(list, attrs)

  def rename_list(list, name) do
    changeset = List.changeset(list, %{name: name})

    changeset =
      if Changeset.changed?(changeset, :name),
        do: Changeset.put_change(changeset, :last_edited_at, now()),
        else: changeset

    result = Repo.update(changeset)

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
          asc: t.position,
          asc: t.created_at,
          asc: t.id
        ],
        preload: [:assignee, :created_by, :updated_by]
      )
    )
  end

  def next_task_position(list_id) do
    (Repo.aggregate(
       from(t in Task, where: t.list_id == ^list_id and is_nil(t.deleted_at)),
       :max,
       :position
     ) || -1) + 1
  end

  def reorder_task(actor, list_id, id, target_id, after?) when is_boolean(after?) do
    result =
      Repo.transaction(fn ->
        actor_id!(actor)
        tasks = list_tasks(list_id)
        task = Enum.find(tasks, &(to_string(&1.id) == id))
        target = Enum.find(tasks, &(to_string(&1.id) == target_id))

        if is_nil(task) || is_nil(target) || task.id == target.id ||
             task.nested_under != target.nested_under || task.due_on != target.due_on,
           do: Repo.rollback(:invalid_order)

        ids =
          tasks
          |> Enum.filter(
            &(&1.nested_under == task.nested_under && &1.due_on == task.due_on && &1.id != task.id)
          )
          |> Enum.map(& &1.id)

        index = Enum.find_index(ids, &(&1 == target.id)) + if(after?, do: 1, else: 0)
        save_positions(Task, Elixir.List.insert_at(ids, index, task.id))
        mark_list_edited(list_id)
      end)

    if match?({:ok, _}, result), do: broadcast(list_id)
    result
  end

  def reorder_task(_actor, _list_id, _id, _target_id, _after?), do: {:error, :invalid_order}

  defp save_positions(schema, ids) do
    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, position} ->
      Repo.update_all(from(row in schema, where: row.id == ^id and row.position != ^position),
        set: [position: position]
      )
    end)
  end

  def get_task!(list_id, id),
    do: get_task(list_id, id) || raise(Ecto.NoResultsError, queryable: Task)

  def get_task(list_id, id) do
    Repo.one(
      from(t in Task,
        where: t.list_id == ^list_id and t.id == ^id and is_nil(t.deleted_at),
        preload: [:created_by, :updated_by]
      )
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

  def move_task(actor, %Task{} = task, list_id) do
    case get_list(list_id) do
      nil ->
        {:error, :list_not_found}

      %List{id: id} when id == task.list_id ->
        {:ok, task}

      %List{id: id} ->
        result =
          task
          |> Task.changeset(%{nested_under: nil})
          |> Changeset.put_change(:list_id, id)
          |> Changeset.put_change(:updated_by_id, actor_id!(actor))
          |> write(:update)

        if match?({:ok, _}, result), do: broadcast(task.list_id)
        result
    end
  end

  def set_completed(actor, id, completed) when is_boolean(completed) do
    actor_id = actor_id!(actor)

    case Repo.one(from(t in Task, where: t.id == ^id and is_nil(t.deleted_at))) do
      nil ->
        {:error, :not_found}

      task ->
        if task.completed_at != nil == completed do
          {:ok, task, :ok}
        else
          task
          |> Changeset.change(completed_at: if(completed, do: now()))
          |> Changeset.put_change(:updated_by_id, actor_id)
          |> write(:update)
          |> case do
            {:ok, saved} ->
              notification = if completed, do: To.Reminders.notify_completion(saved), else: :ok
              {:ok, saved, notification}

            error ->
              error
          end
        end
    end
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
              set: [
                nested_under: new_name,
                updated_by_id: actor_id,
                updated_at: now(),
                last_changed_fields: ["nested_under"]
              ]
            )

          mark_list_edited(list_id)
          count
        end
      end)

    if match?({:ok, _}, result), do: broadcast(list_id)
    result
  end

  def subscribe(list_id), do: Phoenix.PubSub.subscribe(To.PubSub, "tasks:#{list_id}")
  def subscribe_lists, do: Phoenix.PubSub.subscribe(To.PubSub, "lists")

  defp write(changeset, operation) do
    changeset =
      if operation == :update do
        fields =
          [
            :title,
            :description,
            :due_on,
            :assignee_id,
            :nested_under,
            :list_id,
            :completed_at,
            :deleted_at
          ]
          |> Enum.filter(&Changeset.changed?(changeset, &1))
          |> Enum.map(&Atom.to_string/1)

        if fields == [],
          do: Changeset.delete_change(changeset, :updated_by_id),
          else: Changeset.put_change(changeset, :last_changed_fields, fields)
      else
        changeset
      end

    result =
      Repo.transaction(fn ->
        changeset =
          if operation == :insert ||
               Enum.any?([:due_on, :nested_under, :list_id], &Changeset.changed?(changeset, &1)) do
            Changeset.put_change(
              changeset,
              :position,
              next_task_position(Changeset.get_field(changeset, :list_id))
            )
          else
            changeset
          end

        task =
          case apply(Repo, operation, [changeset]) do
            {:ok, task} -> task
            {:error, error} -> Repo.rollback(error)
          end

        if operation == :insert || map_size(changeset.changes) > 0 do
          mark_list_edited(task.list_id)

          if task.list_id != changeset.data.list_id,
            do: mark_list_edited(changeset.data.list_id)
        end

        if To.Sync.needed?(changeset, task) do
          case task |> To.Sync.enqueue() |> Oban.insert() do
            {:ok, _} -> :ok
            {:error, error} -> Repo.rollback(error)
          end
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
    Phoenix.PubSub.broadcast(To.PubSub, "lists", :lists_changed)
    To.Sync.broadcast_status()
  end

  def mark_list_edited(list_id) do
    Repo.update_all(from(l in List, where: l.id == ^list_id), set: [last_edited_at: now()])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
