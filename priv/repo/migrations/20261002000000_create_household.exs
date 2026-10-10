defmodule To.Repo.Migrations.CreateHousehold do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string
      add :google_sub, :string
      add :google_refresh_token, :string
      add :google_task_list_id, :string
      add :reminder_time, :time, null: false, default: "18:00:00"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:name])
    create unique_index(:users, [:email])
    create unique_index(:users, [:google_sub])

    create table(:lists) do
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:lists, [:name])

    create table(:tasks) do
      add :title, :string, null: false
      add :description, :text
      add :due_on, :date
      add :nested_under, :string
      add :completed_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :list_id, references(:lists), null: false
      add :assignee_id, references(:users)
      add :created_by_id, references(:users), null: false
      add :updated_by_id, references(:users), null: false
      timestamps(inserted_at: :created_at, type: :utc_datetime)
    end

    create index(:tasks, [:list_id, :due_on])
    create index(:tasks, [:list_id, :nested_under])

    create table(:google_exports) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users), null: false
      add :google_task_id, :string, null: false
      add :google_list_id, :string, null: false
      add :payload_hash, :string
      add :synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:google_exports, [:task_id, :user_id])

    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :time_zone, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
