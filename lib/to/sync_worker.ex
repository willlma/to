defmodule To.SyncWorker do
  use Oban.Worker,
    queue: :google_sync,
    max_attempts: 12,
    unique: [period: :infinity, keys: [:task_id], states: [:available, :scheduled, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}), do: To.Sync.run(task_id)
end
