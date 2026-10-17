defmodule To.Repo.Migrations.AddListDeletion do
  use Ecto.Migration

  def change do
    alter table(:lists) do
      add :deleted_at, :utc_datetime
    end

    drop unique_index(:lists, [:name])
    create unique_index(:lists, [:name], where: "deleted_at IS NULL")
  end
end
