defmodule To.GoogleExport do
  use Ecto.Schema
  import Ecto.Changeset

  schema "google_exports" do
    belongs_to(:task, To.Tasks.Task)
    belongs_to(:user, To.Accounts.User)
    field(:google_task_id, :string)
    field(:google_list_id, :string)
    field(:payload_hash, :string)
    field(:synced_at, :utc_datetime)
    timestamps(type: :utc_datetime)
  end

  def changeset(export, attrs) do
    export
    |> cast(attrs, [
      :task_id,
      :user_id,
      :google_task_id,
      :google_list_id,
      :payload_hash,
      :synced_at
    ])
    |> validate_required([:task_id, :user_id, :google_task_id, :google_list_id, :payload_hash])
    |> unique_constraint([:task_id, :user_id])
  end
end
