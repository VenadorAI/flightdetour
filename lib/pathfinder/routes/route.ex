defmodule Pathfinder.Routes.Route do
  use Ecto.Schema
  import Ecto.Changeset

  schema "routes" do
    belongs_to :origin_city, Pathfinder.Routes.City
    belongs_to :destination_city, Pathfinder.Routes.City
    belongs_to :via_hub_city, Pathfinder.Routes.City

    field :route_name, :string
    field :carrier_notes, :string
    field :path_geojson, :map
    field :distance_km, :integer
    field :typical_duration_minutes, :integer
    field :corridor_family, :string
    field :is_active, :boolean, default: true
    field :last_reviewed_at, :utc_datetime

    has_one :score, Pathfinder.Routes.RouteScore
    has_many :disruption_factors, Pathfinder.Routes.RouteDisruptionFactor

    timestamps(type: :utc_datetime)
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :origin_city_id, :destination_city_id, :via_hub_city_id,
      :route_name, :carrier_notes, :path_geojson, :corridor_family,
      :distance_km, :typical_duration_minutes, :is_active, :last_reviewed_at
    ])
    |> validate_required([:origin_city_id, :destination_city_id, :route_name, :path_geojson])
    |> validate_number(:distance_km, greater_than: 0)
  end
end
