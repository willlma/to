defmodule To.Tasks.List do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lists" do
    field(:name, :string)
    field(:deleted_at, :utc_datetime)
    has_many(:tasks, To.Tasks.Task)
    timestamps(type: :utc_datetime)
  end

  def changeset(list, attrs) do
    list
    |> cast(attrs, [:name])
    |> update_change(:name, &trim_name/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:name)
  end

  defp trim_name(nil), do: nil
  defp trim_name(value), do: String.trim(value)
end
