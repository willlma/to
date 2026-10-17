defmodule To.Tasks.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:due_on, :date)
    field(:nested_under, :string)
    field(:completed_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:google_import_id, :string)
    belongs_to(:google_import_user, To.Accounts.User)
    belongs_to(:list, To.Tasks.List)
    belongs_to(:assignee, To.Accounts.User)
    belongs_to(:created_by, To.Accounts.User)
    belongs_to(:updated_by, To.Accounts.User)
    timestamps(inserted_at: :created_at, type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :due_on, :assignee_id, :nested_under])
    |> update_change(:title, &trim_title/1)
    |> update_change(:nested_under, &normalize_group/1)
    |> validate_required([:title, :list_id, :created_by_id, :updated_by_id])
    |> validate_length(:title, max: 500)
    |> validate_length(:description, max: 8_000)
    |> validate_length(:nested_under, max: 100)
    |> foreign_key_constraint(:list_id)
    |> foreign_key_constraint(:assignee_id)
    |> foreign_key_constraint(:created_by_id)
    |> foreign_key_constraint(:updated_by_id)
    |> unique_constraint([:google_import_user_id, :google_import_id])
  end

  defp trim_title(nil), do: nil
  defp trim_title(value), do: String.trim(value)

  def normalize_group(nil), do: nil

  def normalize_group(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end
end
