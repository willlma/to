defmodule To.Repo.Migrations.AddListAndTaskPositions do
  use Ecto.Migration

  def up do
    alter table(:lists) do
      add :position, :integer, null: false, default: 0
    end

    alter table(:tasks) do
      add :position, :integer, null: false, default: 0
    end

    execute """
    WITH ranked AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY inserted_at, id) - 1 AS position FROM lists
    )
    UPDATE lists SET position = (SELECT position FROM ranked WHERE ranked.id = lists.id)
    """

    execute """
    WITH ranked AS (
      SELECT id, ROW_NUMBER() OVER (PARTITION BY list_id ORDER BY created_at, id) - 1 AS position
      FROM tasks
    )
    UPDATE tasks SET position = (SELECT position FROM ranked WHERE ranked.id = tasks.id)
    """
  end

  def down do
    alter table(:tasks), do: remove(:position)
    alter table(:lists), do: remove(:position)
  end
end
