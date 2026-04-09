defmodule PathfinderWeb.RouteDetailLive do
  use PathfinderWeb, :live_view
  alias Pathfinder.{Routes, Disruption, CitySlug, Analytics}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    route = Routes.get_route!(id)
    zones = Disruption.active_zones_geojson()
    pair_slug = CitySlug.pair_slug(route.origin_city.name, route.destination_city.name)
    sibling_routes = Routes.find_routes(route.origin_city_id, route.destination_city_id)
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
            "name" => "#{route.origin_city.name} → #{route.destination_city.name}",
            "item" => "#{base}/route/#{pair_slug}"
          },
          %{
            "@type" => "ListItem",
            "position" => 3,
            "name" => route.route_name,
            "item" => "#{base}/routes/#{route.id}"
          }
        ]
      })

    socket =
      socket
      |> assign(:page_title, "#{route.origin_city.name} → #{route.destination_city.name} #{route.route_name} · FlightDetour")
      |> assign(:page_description, build_detail_description(route))
      |> assign(:page_canonical, "#{base}/routes/#{route.id}")
      |> assign(:structured_data, structured_data)
      |> assign(:route, route)
      |> assign(:zones, zones)
      |> assign(:show_sources, false)
      |> assign(:show_analysis, false)
      |> assign(:show_map, false)
      |> assign(:pair_slug, pair_slug)
      |> assign(:sibling_routes, Enum.reject(sibling_routes, & &1.id == route.id))

    socket =
      # push_event here handles re-navigation between sibling routes when the map
      # is already open (show_map: true). On first load show_map is false so the
      # hook doesn't exist yet — the toggle-map handler re-pushes when map opens.
      if connected?(socket) && route.score && route.path_geojson do
        push_event(socket, "render-routes", %{
          routes: [
            %{
              id: route.id,
              route_name: route.route_name,
              label: route.score.label,
              color: Pathfinder.Routes.RouteScore.map_color(route.score.label),
              composite_score: route.score.composite_score,
              geojson: route.path_geojson
            }
          ],
          zones: zones,
          selected_id: route.id
        })
      else
        socket
      end

    Analytics.track("advisory_opened", %{
      route_id: route.id,
      pair_slug: pair_slug,
      label: route.score && route.score.label,
      score: route.score && route.score.composite_score
    })

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle-sources", _params, socket) do
    {:noreply, assign(socket, :show_sources, !socket.assigns.show_sources)}
  end

  def handle_event("toggle-analysis", _params, socket) do
    {:noreply, assign(socket, :show_analysis, !socket.assigns.show_analysis)}
  end

  def handle_event("toggle-map", _params, socket) do
    show_map = !socket.assigns.show_map
    socket = assign(socket, :show_map, show_map)

    # Push render-routes when revealing the map — the MapHook doesn't exist
    # in the DOM until show_map is true, so push_event in handle_params fires
    # before the hook is mounted and the event is dropped. Re-push here so the
    # hook receives data immediately after it mounts from the LiveView patch.
    socket =
      if show_map do
        route = socket.assigns.route
        zones = socket.assigns.zones

        if route.score && route.path_geojson do
          push_event(socket, "render-routes", %{
            routes: [
              %{
                id: route.id,
                route_name: route.route_name,
                label: route.score.label,
                color: Pathfinder.Routes.RouteScore.map_color(route.score.label),
                composite_score: route.score.composite_score,
                geojson: route.path_geojson
              }
            ],
            zones: zones,
            selected_id: route.id
          })
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  defp back_path(_route, pair_slug) do
    ~p"/route/#{pair_slug}"
  end

  defp duration_label(nil), do: nil
  defp duration_label(mins) do
    h = div(mins, 60)
    m = rem(mins, 60)
    if m == 0, do: "~#{h}h", else: "~#{h}h #{m}m"
  end

  defp build_detail_description(route) do
    if route.score do
      label = route.score.label |> Atom.to_string() |> String.capitalize()
      score = route.score.composite_score

      airspace = case route.score.airspace_score do
        0 -> "Clean airspace."
        1 -> "Near an advisory zone."
        2 -> "Crosses an active advisory zone."
        _ -> "High advisory zone exposure."
      end

      "#{route.origin_city.name} → #{route.destination_city.name} #{route.route_name}: #{label} (#{score}/100). #{airspace} Airspace exposure, corridor analysis, and booking advisory."
    else
      "#{route.origin_city.name} → #{route.destination_city.name} #{route.route_name} — detailed corridor assessment."
    end
  end
end
