defmodule To.Repo.Migrations.AddGoogleImportIdentity do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :google_import_user_id, references(:users)
      add :google_import_id, :string
    end

    create unique_index(:tasks, [:google_import_user_id, :google_import_id])
  end
end
