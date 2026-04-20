defmodule Pathfinder.Disruption do
  import Ecto.Query
  alias Pathfinder.{Repo, RouteCache}
  alias Pathfinder.Disruption.DisruptionZone
  alias Pathfinder.Routes.Route

  def list_active_zones do
    DisruptionZone
    |> where([z], z.status in [:active, :monitoring])
    |> order_by([z], [desc: z.severity, asc: z.name])
    |> Repo.all()
  end

  def get_zone!(id), do: Repo.get!(DisruptionZone, id)

  def get_zone_by_slug(slug) do
    Repo.get_by(DisruptionZone, slug: slug)
  end

  def routes_for_zone(zone_id) do
    Route
    |> join(:inner, [r], f in Pathfinder.Routes.RouteDisruptionFactor,
      on: f.route_id == r.id and f.disruption_zone_id == ^zone_id
    )
    |> where([r], r.is_active == true)
    |> preload([:origin_city, :destination_city, :score])
    |> distinct([r], r.id)
    |> Repo.all()
    |> Enum.map(fn route -> {route, route.score} end)
  end

  @doc "Returns the most recent last_checked_at across all zones, or nil if never checked."
  def latest_source_check do
    DisruptionZone
    |> where([z], not is_nil(z.last_checked_at))
    |> order_by([z], [desc: z.last_checked_at])
    |> limit(1)
    |> select([z], z.last_checked_at)
    |> Repo.one()
  end

  def active_zones_geojson do
    RouteCache.fetch(:active_zones_geojson, 300, fn ->
      list_active_zones()
      |> Enum.filter(& &1.boundary_geojson)
      |> Enum.map(fn zone ->
        %{
          id: zone.id,
          slug: zone.slug,
          name: zone.name,
          severity: zone.severity,
          color: DisruptionZone.severity_color(zone.severity),
          opacity: DisruptionZone.severity_opacity(zone.severity),
          geojson: zone.boundary_geojson,
          last_changed_at: zone.last_changed_at
        }
      end)
    end)
  end
end
