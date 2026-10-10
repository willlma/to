defmodule To.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field(:name, :string)
    field(:email, :string)
    field(:google_sub, :string)
    field(:google_refresh_token, :string, redact: true)
    field(:google_task_list_id, :string)
    field(:reminder_time, :time, default: ~T[18:00:00])

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :name,
      :email,
      :google_sub,
      :google_refresh_token,
      :google_task_list_id,
      :reminder_time
    ])
    |> validate_required([:name, :reminder_time])
    |> validate_inclusion(:name, ["Nicole", "Will"])
    |> unique_constraint(:name)
    |> unique_constraint(:email)
    |> unique_constraint(:google_sub)
  end
end
