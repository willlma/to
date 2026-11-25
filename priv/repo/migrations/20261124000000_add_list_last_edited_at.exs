defmodule To.Repo.Migrations.AddListLastEditedAt do
  use Ecto.Migration

  def up do
    alter table(:lists) do
      add :last_edited_at, :utc_datetime
    end

    execute """
    UPDATE lists
    SET last_edited_at = MAX(updated_at, COALESCE(
      (SELECT MAX(tasks.updated_at) FROM tasks WHERE tasks.list_id = lists.id),
      updated_at
    ))
    """
  end

  def down do
    alter table(:lists), do: remove(:last_edited_at)
  end
end
