defmodule To.Repo.Migrations.AddPebbleToken do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :pebble_token_hash, :binary
    end

    create unique_index(:users, [:pebble_token_hash])
  end
end
