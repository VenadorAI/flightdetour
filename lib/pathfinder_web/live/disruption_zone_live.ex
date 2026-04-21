defmodule PathfinderWeb.DisruptionZoneLive do
  use PathfinderWeb, :live_view
  alias Pathfinder.Disruption
  alias Pathfinder.Disruption.DisruptionZone

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    case Disruption.get_zone_by_slug(slug) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      zone ->
        affected_routes = Disruption.routes_for_zone(zone.id)
        base = PathfinderWeb.Endpoint.url()

        structured_data =
          Jason.encode!(%{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" => [
              %{"@type" => "ListItem", "position" => 1, "name" => "FlightDetour", "item" => "#{base}/"},
              %{
                "@type" => "ListItem",
                "position" => 2,
                "name" => "#{zone.name} Disruption Zone",
                "item" => "#{base}/disruption/#{zone.slug}"
              }
            ]
          })

        socket =
          socket
          |> assign(:page_title, "#{zone.name} Disruption Zone · FlightDetour")
          |> assign(:page_description, "#{zone.name} airspace disruption zone — #{zone_status_text(zone.status)} affecting #{length(affected_routes)} routes. See which flight corridors are impacted and what alternatives exist.")
          |> assign(:page_canonical, "#{base}/disruption/#{zone.slug}")
          |> assign(:structured_data, structured_data)
          |> assign(:zone, zone)
          |> assign(:affected_routes, affected_routes)
          |> then(fn s -> if zone.status == :resolved, do: assign(s, :page_noindex, true), else: s end)

        socket =
          if connected?(socket) && zone.boundary_geojson do
            push_event(socket, "render-zone", %{
              zone: %{
                id: zone.id,
                name: zone.name,
                color: DisruptionZone.severity_color(zone.severity),
                opacity: DisruptionZone.severity_opacity(zone.severity),
                geojson: zone.boundary_geojson
              }
            })
          else
            socket
          end

        {:noreply, socket}
    end
  end

  # ZoneMapHook fires this when MapLibre's load event fires before the WS push_event
  # arrives (fast tile cache, slow socket, reconnect). Re-pushes the zone boundary.
  @impl true
  def handle_event("zone-map-ready", _params, socket) do
    zone = socket.assigns.zone
    socket =
      if zone.boundary_geojson do
        push_event(socket, "render-zone", %{
          zone: %{
            id: zone.id,
            name: zone.name,
            color: DisruptionZone.severity_color(zone.severity),
            opacity: DisruptionZone.severity_opacity(zone.severity),
            geojson: zone.boundary_geojson
          }
        })
      else
        socket
      end
    {:noreply, socket}
  end

  defp zone_status_text(:active), do: "active advisory"
  defp zone_status_text(:monitoring), do: "advisory under monitoring"
  defp zone_status_text(:resolved), do: "resolved advisory (historical)"

  defp zone_type_label(:conflict), do: "Active Conflict"
  defp zone_type_label(:closed_airspace), do: "Closed Airspace"
  defp zone_type_label(:advisory), do: "Advisory"
  defp zone_type_label(:congestion), do: "Corridor Congestion"

  defp status_label(:active), do: "Active"
  defp status_label(:monitoring), do: "Monitoring"
  defp status_label(:resolved), do: "Resolved"

  defp status_color(:active), do: "text-red-400"
  defp status_color(:monitoring), do: "text-amber-400"
  defp status_color(:resolved), do: "text-emerald-400"
end
