defmodule To.ReminderWorker do
  use Oban.Worker, queue: :reminders, max_attempts: 5
  alias To.{PushSubscription, Repo}
  alias To.Accounts.User
  alias To.Tasks.Task

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    task = Repo.get(Task, args["task_id"])
    subscription = Repo.get(PushSubscription, args["subscription_id"])
    user = if subscription, do: Repo.get(User, subscription.user_id)

    if current?(task, subscription, user, args) do
      payload =
        Jason.encode!(%{
          title: "Due tomorrow",
          body: task.title,
          tag: "task-#{task.id}",
          url: "/lists/#{task.list_id}"
        })

      case send_notification(subscription, payload, ttl: 3600, topic: "task-#{task.id}") do
        {:error, :subscription_expired} -> :ok
        result -> result
      end
    else
      :ok
    end
  end

  def send_notification(subscription, payload, opts) do
    push = %ExNudge.Subscription{
      endpoint: subscription.endpoint,
      keys: %{p256dh: subscription.p256dh, auth: subscription.auth}
    }

    transport = transport()

    case transport.send_notification(push, payload, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} when reason in [:subscription_expired, {:http_error, 404}] ->
        Repo.delete(subscription)
        {:error, :subscription_expired}

      {:error, reason} ->
        {:error, reason}
    end
  end

  if Mix.env() == :test do
    defp transport, do: Application.get_env(:to, :push_transport, ExNudge)
  else
    defp transport, do: ExNudge
  end

  defp current?(nil, _, _, _), do: false
  defp current?(_, nil, _, _), do: false
  defp current?(_, _, nil, _), do: false

  defp current?(task, subscription, user, args) do
    !task.completed_at && !task.deleted_at && task.assignee_id == user.id &&
      task.due_on && Date.to_iso8601(task.due_on) == args["due_on"] &&
      Time.to_iso8601(user.reminder_time) == args["reminder_time"] &&
      subscription.time_zone == args["time_zone"] &&
      Date.compare(
        task.due_on,
        Date.add(
          DateTime.shift_zone!(DateTime.utc_now(), subscription.time_zone) |> DateTime.to_date(),
          1
        )
      ) == :eq
  end
end
