defmodule Pathfinder.Repo.Migrations.CreateSearchEvents do
  use Ecto.Migration

  def change do
    create table(:search_events) do
      add :event_name, :string, null: false
      add :origin, :string
      add :destination, :string
      add :pair_slug, :string
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:search_events, [:event_name])
    create index(:search_events, [:origin])
    create index(:search_events, [:destination])
    create index(:search_events, [:pair_slug])
    create index(:search_events, [:inserted_at])
  end
end
