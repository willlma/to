defmodule To.Repo.Migrations.AddTaskLastChangedFields do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :last_changed_fields, {:array, :string}
    end
  end
end
