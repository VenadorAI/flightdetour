defmodule Pathfinder.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  def change do
    create table(:routes) do
      add :origin_city_id, references(:cities, on_delete: :restrict), null: false
      add :destination_city_id, references(:cities, on_delete: :restrict), null: false
      add :via_hub_city_id, references(:cities, on_delete: :restrict)
      add :route_name, :string, null: false
      add :carrier_notes, :string
      add :path_geojson, :map, null: false
      add :distance_km, :integer
      add :typical_duration_minutes, :integer
      add :is_active, :boolean, default: true, null: false
      add :last_reviewed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:routes, [:origin_city_id, :destination_city_id])
    create index(:routes, [:is_active])

    # Factors linking routes to disruption zones
    create table(:route_disruption_factors) do
      add :route_id, references(:routes, on_delete: :delete_all), null: false
      add :disruption_zone_id, references(:disruption_zones, on_delete: :delete_all), null: false
      # :airspace_exposure | :corridor_dependency | :hub_risk | :complexity | :operational
      add :factor_type, :string, null: false
      # 0-3 integer
      add :factor_score, :integer, null: false
      add :explanation_text, :text, null: false
      add :assessed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:route_disruption_factors, [:route_id])
    create index(:route_disruption_factors, [:disruption_zone_id])
  end
end
