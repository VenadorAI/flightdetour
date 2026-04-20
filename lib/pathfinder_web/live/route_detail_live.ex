defmodule PathfinderWeb.RouteDetailLive do
  use PathfinderWeb, :live_view
  alias Pathfinder.{Routes, Disruption, CitySlug, Analytics}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    t0 = System.monotonic_time(:millisecond)
    route = Routes.get_route!(id)
    t1 = System.monotonic_time(:millisecond)
    zones = Disruption.active_zones_geojson()
    t2 = System.monotonic_time(:millisecond)
    pair_slug = CitySlug.pair_slug(route.origin_city.name, route.destination_city.name)
    sibling_routes = Routes.find_routes(route.origin_city_id, route.destination_city_id)
    t3 = System.monotonic_time(:millisecond)

    iata_o = hd(route.origin_city.iata_codes || [""])
    iata_d = hd(route.destination_city.iata_codes || [""])
    outbound_links = Pathfinder.Outbound.search_links(iata_o, iata_d)
    sky = Enum.find(outbound_links, fn {k, _, _} -> k == :skyscanner end)
    sec_links = Enum.reject(outbound_links, fn {k, _, _} -> k == :skyscanner end)

    {detail_freshness, zone_checked_at, changed_zones} =
      if route.score do
        df = Pathfinder.Advisory.Freshness.for_score(route.score)

        zc =
          route.disruption_factors
          |> Enum.map(& &1.disruption_zone && &1.disruption_zone.last_checked_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(DateTime, fn -> nil end)

        cz =
          if df == :review_required do
            Enum.filter(route.disruption_factors, fn f ->
              f.disruption_zone != nil and
                f.disruption_zone.last_changed_at != nil and
                (is_nil(route.last_reviewed_at) or
                   DateTime.compare(f.disruption_zone.last_changed_at, route.last_reviewed_at) == :gt)
            end)
          else
            []
          end

        {df, zc, cz}
      else
        {:current, nil, []}
      end

    base = PathfinderWeb.Endpoint.url()

    require Logger
    Logger.info("[RouteDetailLive] id=#{id} connected=#{connected?(socket)} get_route=#{t1 - t0}ms zones=#{t2 - t1}ms find_routes=#{t3 - t2}ms total=#{t3 - t0}ms")

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
      |> assign(:page_title, "Flights from #{route.origin_city.name} to #{route.destination_city.name}: #{route.route_name} · FlightDetour")
      |> assign(:page_description, build_detail_description(route))
      |> assign(:page_canonical, "#{base}/routes/#{route.id}")
      |> assign(:structured_data, structured_data)
      |> assign(:route, route)
      |> assign(:zones, zones)
      |> assign(:show_analysis, false)
      |> assign(:pair_slug, pair_slug)
      |> assign(:sibling_routes, Enum.reject(sibling_routes, & &1.id == route.id))
      |> assign(:sky, sky)
      |> assign(:sec_links, sec_links)
      |> assign(:iata_o, iata_o)
      |> assign(:iata_d, iata_d)
      |> assign(:cta_label, cta_label(route))
      |> assign(:detail_freshness, detail_freshness)
      |> assign(:zone_checked_at, zone_checked_at)
      |> assign(:changed_zones, changed_zones)

    # Push on WebSocket connect. Both mobile and desktop map elements are always
    # in DOM. The visibility guard (offsetWidth===0) in MapHook ensures only the
    # relevant instance initialises on each device — the other exits early and
    # never calls handleEvent, so it won't receive this push.
    socket =
      if connected?(socket) && route.score && route.path_geojson do
        push_event(socket, "render-routes", %{
          routes: [route_payload(route, iata_o, iata_d)],
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
  def handle_event("toggle-analysis", _params, socket) do
    {:noreply, assign(socket, :show_analysis, !socket.assigns.show_analysis)}
  end

  # Build the route map payload — shared between initial push and toggle-map re-push.
  # Includes origin/dest IATA for markers and via hub for contextual CTA.
  defp route_payload(route, iata_o, iata_d) do
    %{
      id: route.id,
      route_name: route.route_name,
      label: route.score.label,
      color: Pathfinder.Routes.RouteScore.map_color(route.score.label),
      composite_score: route.score.composite_score,
      geojson: route.path_geojson,
      origin_iata: iata_o,
      origin_name: route.origin_city.name,
      dest_iata: iata_d,
      dest_name: route.destination_city.name
    }
  end

  # Contextual CTA copy: reflects the actual route hub and safety level.
  # Converts generic "Search on Skyscanner" into something that tells users
  # exactly what they're booking and why.
  defp cta_label(route) do
    hub = route.via_hub_city && route.via_hub_city.name
    label = route.score && route.score.label

    cond do
      hub && label == :flowing -> "Book via #{hub} — recommended route"
      hub                      -> "Find flights via #{hub}"
      label == :flowing        -> "Book this safer route"
      label == :watchful       -> "Search flights — monitor conditions"
      true                     -> "Search flights for this route"
    end
  end

  defp back_path(_route, pair_slug), do: ~p"/route/#{pair_slug}"

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

      airspace =
        case route.score.airspace_score do
          0 -> "Clean airspace, no rerouting concerns."
          1 -> "Near an advisory zone but not through it."
          2 -> "This route crosses an active airspace advisory zone."
          _ -> "Route transits an active conflict zone."
        end

      "#{route.route_name} from #{route.origin_city.name} to #{route.destination_city.name} — currently #{label} (#{score}/100). #{airspace} See if this is still the better option before you book."
    else
      "#{route.route_name} from #{route.origin_city.name} to #{route.destination_city.name} — route details and how this path compares to alternatives right now."
    end
  end
end
