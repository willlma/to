defmodule To.Reminders do
  import Ecto.Query
  alias To.{PushSubscription, ReminderWorker, Repo}
  alias To.Accounts.User
  alias To.Tasks.Task

  def configured? do
    Enum.all?([:vapid_public_key, :vapid_private_key, :vapid_subject], fn key ->
      value = Application.get_env(:ex_nudge, key)
      is_binary(value) and byte_size(value) > 0
    end)
  end

  # Called in the same transaction as task writes; no network work happens here.
  def schedule(task) do
    Oban.cancel_all_jobs(
      from j in Oban.Job,
        where: j.worker == "To.ReminderWorker",
        where: fragment("json_extract(?, '$.task_id')", j.args) == ^task.id
    )

    if task.due_on && task.assignee_id && !task.completed_at && !task.deleted_at do
      user = Repo.get!(User, task.assignee_id)

      Repo.all(from s in PushSubscription, where: s.user_id == ^user.id)
      |> Enum.reduce_while(:ok, fn subscription, :ok ->
        case scheduled_at(task, user, subscription) do
          %DateTime{} = at ->
            if DateTime.compare(at, DateTime.utc_now()) == :gt do
              args = %{
                task_id: task.id,
                subscription_id: subscription.id,
                due_on: Date.to_iso8601(task.due_on),
                reminder_time: Time.to_iso8601(user.reminder_time),
                time_zone: subscription.time_zone
              }

              case args |> ReminderWorker.new(scheduled_at: at) |> Oban.insert() do
                {:ok, _} -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            else
              {:cont, :ok}
            end

          _ ->
            {:halt, {:error, :invalid_timezone}}
        end
      end)
    else
      :ok
    end
  end

  def scheduled_at(task, user, subscription) do
    case DateTime.new(Date.add(task.due_on, -1), user.reminder_time, subscription.time_zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      # A repeated clock time means the first occurrence; a nonexistent time
      # means the first valid time after the daylight-saving gap.
      {:ambiguous, first, _} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC")
      _ -> nil
    end
  end

  def subscribe(user, %{"endpoint" => endpoint, "keys" => keys, "time_zone" => zone})
      when is_binary(endpoint) and is_map(keys) and is_binary(zone) do
    transaction(fn ->
      subscription = Repo.get_by(PushSubscription, endpoint: endpoint) || %PushSubscription{}

      attrs = %{
        user_id: user.id,
        endpoint: endpoint,
        p256dh: keys["p256dh"],
        auth: keys["auth"],
        time_zone: zone
      }

      saved =
        subscription |> PushSubscription.changeset(attrs) |> Repo.insert_or_update() |> unwrap!()

      reschedule_user!(user.id)
      saved
    end)
  end

  def subscribe(_, _), do: {:error, :invalid_subscription}

  def unsubscribe(user, endpoint) when is_binary(endpoint) do
    Repo.delete_all(
      from s in PushSubscription, where: s.user_id == ^user.id and s.endpoint == ^endpoint
    )

    :ok
  end

  def unsubscribe(_, _), do: {:error, :invalid_subscription}

  def test_notification(user, endpoint) when is_binary(endpoint) do
    with true <- configured?(),
         %PushSubscription{} = subscription <-
           Repo.get_by(PushSubscription, user_id: user.id, endpoint: endpoint) do
      payload =
        Jason.encode!(%{title: "Hello from town", tag: "test-notification", url: "/settings"})

      ReminderWorker.send_notification(subscription, payload, ttl: 60, topic: "test-notification")
    else
      _ -> {:error, :invalid_subscription}
    end
  end

  def test_notification(_, _), do: {:error, :invalid_subscription}

  def update_reminder_time(user, value) when is_binary(value) do
    value = if is_binary(value) && byte_size(value) == 5, do: value <> ":00", else: value

    with {:ok, time} <- Time.from_iso8601(value) do
      transaction(fn ->
        saved = user |> Ecto.Changeset.change(reminder_time: time) |> Repo.update() |> unwrap!()
        reschedule_user!(saved.id)
        saved
      end)
    else
      _ -> {:error, :invalid_time}
    end
  end

  def update_reminder_time(_, _), do: {:error, :invalid_time}

  defp reschedule_user!(id) do
    Repo.all(from t in Task, where: t.assignee_id == ^id)
    |> Enum.each(fn task ->
      case schedule(task) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp transaction(fun), do: Repo.transaction(fun)
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
