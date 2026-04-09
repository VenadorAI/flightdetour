defmodule Pathfinder.Repo.Migrations.CreateDisruptionZones do
  use Ecto.Migration

  def change do
    create table(:disruption_zones) do
      add :name, :string, null: false
      add :slug, :string, null: false
      # :conflict | :closed_airspace | :advisory | :congestion
      add :zone_type, :string, null: false
      # :active | :monitoring | :resolved
      add :status, :string, null: false, default: "active"
      # :low | :moderate | :high | :critical
      add :severity, :string, null: false, default: "moderate"
      add :summary_text, :text, null: false
      add :detail_text, :text
      add :boundary_geojson, :map
      add :affected_regions, {:array, :string}, default: []
      add :source_urls, {:array, :string}, default: []
      add :valid_from, :utc_datetime
      add :valid_until, :utc_datetime
      add :last_updated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:disruption_zones, [:slug])
    create index(:disruption_zones, [:status])
    create index(:disruption_zones, [:zone_type])
  end
end
