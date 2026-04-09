defmodule PathfinderWeb.ResultsLive do
  use PathfinderWeb, :live_view
  alias Pathfinder.{Routes, Disruption, CitySlug, Analytics}
  alias Pathfinder.Routes.RouteScore

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:routes, [])
     |> assign(:zones, [])
     |> assign(:origin_city, nil)
     |> assign(:destination_city, nil)
     |> assign(:selected_route_id, nil)
     |> assign(:best_route, nil)
     |> assign(:not_covered, false)
     |> assign(:loading, false)
     |> assign(:show_all_routes, false)
     |> assign(:show_compare, false)
     |> assign(:pair_slug, nil)
     |> assign(:nearby_from_origin, [])
     |> assign(:nearby_to_destination, [])
     |> assign(:featured_pairs, [])}
  end

  # ── Canonical pair page: /route/:pair_slug ──────────────────────────────────

  @impl true
  def handle_params(%{"pair_slug" => pair_slug}, _uri, socket) do
    case CitySlug.parse_pair_slug(pair_slug) do
      {:ok, origin_slug, dest_slug} ->
        origin = Routes.get_city_by_slug(origin_slug)
        dest = Routes.get_city_by_slug(dest_slug)

        cond do
          is_nil(origin) or is_nil(dest) ->
            {:noreply, push_navigate(socket, to: ~p"/")}

          true ->
            routes = Routes.find_routes(origin.id, dest.id)

            cond do
              not Enum.empty?(routes) ->
                Analytics.track("pair_page_loaded", %{
                  pair_slug: pair_slug,
                  origin: origin.name,
                  destination: dest.name,
                  route_count: length(routes)
                })

                {:noreply, load_pair(socket, origin, dest, routes, pair_slug)}

              not Enum.empty?(Routes.find_routes(dest.id, origin.id)) ->
                # Redirect to the canonical direction that has actual routes
                reverse = CitySlug.pair_slug(dest.name, origin.name)
                {:noreply, push_navigate(socket, to: ~p"/route/#{reverse}")}

              true ->
                {:noreply, assign_not_covered(socket, origin, dest)}
            end
        end

      :error ->
        {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  # ── Legacy query-param URL: /routes?origin=ID&destination=ID ───────────────
  # Redirects immediately to the canonical slug URL.

  def handle_params(%{"origin" => origin_id, "destination" => destination_id}, _uri, socket) do
    origin = Routes.get_city!(origin_id)
    destination = Routes.get_city!(destination_id)
    slug = CitySlug.pair_slug(origin.name, destination.name)
    {:noreply, push_navigate(socket, to: ~p"/route/#{slug}")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select-route", %{"id" => id}, socket) do
    route_id = String.to_integer(id)
    Analytics.track("route_card_selected", %{route_id: route_id, pair_slug: socket.assigns.pair_slug})

    socket =
      socket
      |> assign(:selected_route_id, route_id)
      |> push_event("highlight-route", %{id: route_id})

    {:noreply, socket}
  end

  def handle_event("route-clicked-on-map", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_route_id, String.to_integer(id))}
  end

  def handle_event("toggle-show-all-routes", _params, socket) do
    {:noreply, assign(socket, :show_all_routes, !socket.assigns.show_all_routes)}
  end

  def handle_event("toggle-compare", _params, socket) do
    {:noreply, assign(socket, :show_compare, !socket.assigns.show_compare)}
  end

  @impl true
  def handle_info({:map_route_selected, id}, socket) do
    {:noreply, assign(socket, :selected_route_id, id)}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp load_pair(socket, origin, destination, routes, pair_slug) do
    zones = Disruption.active_zones_geojson()
    best = Routes.best_route(routes)
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
            "name" => "#{origin.name} → #{destination.name}",
            "item" => "#{base}/route/#{pair_slug}"
          }
        ]
      })

    page_description =
      if best && best.score do
        label_text = best.score.label |> Atom.to_string() |> String.capitalize()
        "#{origin.name} → #{destination.name}: #{best.route_name} rates #{label_text} — #{length(routes)} corridor options compared by airspace exposure and advisory zone impact."
      else
        "#{origin.name} → #{destination.name}: #{length(routes)} corridor options compared by airspace exposure and advisory zone impact."
      end

    socket =
      socket
      |> assign(:page_title, "#{origin.name} → #{destination.name} Route Comparison · FlightDetour")
      |> assign(:page_description, page_description)
      |> assign(:page_canonical, "#{base}/route/#{pair_slug}")
      |> assign(:structured_data, structured_data)
      |> assign(:origin_city, origin)
      |> assign(:destination_city, destination)
      |> assign(:routes, routes)
      |> assign(:zones, zones)
      |> assign(:best_route, best)
      |> assign(:not_covered, false)
      |> assign(:sufficient_coverage, Routes.sufficient_corridor_coverage?(routes))
      |> assign(:selected_route_id, if(best, do: best.id, else: nil))
      |> assign(:latest_source_check, Disruption.latest_source_check())
      |> assign(:show_all_routes, false)
      |> assign(:show_compare, false)
      |> assign(:pair_slug, pair_slug)

    if connected?(socket) do
      push_event(socket, "render-routes", %{
        routes: Routes.routes_as_map_features(routes),
        zones: zones,
        selected_id: if(best, do: best.id, else: nil)
      })
    else
      socket
    end
  end

  defp assign_not_covered(socket, origin, destination) do
    nearby = Routes.nearby_covered_pairs(origin.id, destination.id)

    Analytics.track("uncovered_search", %{
      origin: origin.name,
      destination: destination.name,
      pair_slug: CitySlug.pair_slug(origin.name, destination.name)
    })

    featured_pairs =
      if nearby.from_origin == [] and nearby.to_destination == [] do
        Routes.featured_route_pairs() |> Enum.take(4)
      else
        []
      end

    socket
    |> assign(:page_title, "#{origin.name} → #{destination.name} · FlightDetour")
    |> assign(:page_noindex, true)
    |> assign(:not_covered, true)
    |> assign(:origin_city, origin)
    |> assign(:destination_city, destination)
    |> assign(:routes, [])
    |> assign(:zones, [])
    |> assign(:best_route, nil)
    |> assign(:sufficient_coverage, false)
    |> assign(:selected_route_id, nil)
    |> assign(:latest_source_check, nil)
    |> assign(:pair_slug, CitySlug.pair_slug(origin.name, destination.name))
    |> assign(:nearby_from_origin, nearby.from_origin)
    |> assign(:nearby_to_destination, nearby.to_destination)
    |> assign(:featured_pairs, featured_pairs)
  end

  defp selected?(route, selected_id), do: route.id == selected_id

  # ── Best-route summary helpers ───────────────────────────────────────────────
  # Map numeric factor scores into 3 plain-English labels for the summary block.
  # All inputs are penalty-based (0 = best).

  def summary_labels(score) do
    exposure =
      case score.airspace_score do
        0 -> {"Low", "text-emerald-400/80"}
        1 -> {"Low", "text-emerald-400/65"}
        2 -> {"Moderate", "text-amber-400/80"}
        _ -> {"High", "text-red-400/75"}
      end

    detour =
      case score.complexity_score do
        0 -> "Minimal"
        1 -> "Moderate"
        _ -> "Significant"
      end

    hub =
      case score.hub_score do
        0 -> "Strong"
        1 -> "Mixed"
        _ -> "Limited"
      end

    {exposure, detour, hub}
  end

  def summary_explanation(best_route, all_routes) do
    score = best_route.score
    hub_name = best_route.route_name  # e.g. "Via Istanbul"

    others_with_scores = Enum.filter(all_routes, fn r ->
      r.id != best_route.id && r.score != nil
    end)

    exposure_phrase =
      case score.airspace_score do
        0 -> "clean airspace routing"
        1 -> "lower exposure than Gulf-connected options"
        2 -> "advisory zone exposure — compare with alternatives"
        _ -> "high advisory zone exposure on this corridor"
      end

    hub_phrase =
      case score.hub_score do
        0 -> "strong hub reliability"
        1 -> "reasonable hub reliability"
        _ -> "limited hub options"
      end

    detour_phrase =
      case score.complexity_score do
        0 -> "minimal detour impact"
        1 -> "moderate detour impact"
        _ -> "a longer routing than direct alternatives"
      end

    # If alternatives exist with higher airspace exposure, frame as a relative advantage
    if length(others_with_scores) > 0 do
      max_other_airspace = others_with_scores |> Enum.map(& &1.score.airspace_score) |> Enum.max()
      if score.airspace_score < max_other_airspace do
        "#{hub_name} — #{exposure_phrase}, with #{detour_phrase} and #{hub_phrase}."
      else
        "#{hub_name} scores highest on this corridor — #{exposure_phrase}, with #{detour_phrase}."
      end
    else
      "#{hub_name} — #{exposure_phrase}, with #{detour_phrase} and #{hub_phrase}."
    end
  end

  def pair_verdict(routes, best_route) do
    scored = Enum.filter(routes, & &1.score)
    total = length(scored)
    flowing = Enum.count(scored, fn r -> r.score.label == :flowing end)
    all_exposed = total > 0 && Enum.all?(scored, fn r -> r.score.airspace_score >= 2 end)
    best_name = best_route && best_route.route_name
    best_freshness = best_route && best_route.score &&
      Pathfinder.Advisory.Freshness.for_score(best_route.score)
    stale_best = best_freshness in [:stale, :review_required]

    cond do
      total == 0 ->
        nil

      stale_best && flowing == total && total == 1 ->
        "#{best_name} was last rated Flowing — score may not reflect current advisories."

      stale_best && flowing > 0 ->
        "#{total} routes assessed for this corridor. #{best_name} scores highest — verify advisories before booking."

      flowing == total && total == 1 ->
        "#{best_name} is currently rated Flowing — no advisory zone exposure on this corridor."

      flowing == total ->
        "All #{total} assessed routes are currently rated Flowing."

      all_exposed ->
        "All #{total} assessed routes cross the advisory zone. Compare corridors to find the lowest exposure path."

      flowing > 0 ->
        "#{flowing} of #{total} routes rated Flowing. #{best_name} is the strongest current option."

      true ->
        "#{total} routes assessed for this corridor. #{best_name} scores highest."
    end
  end
end
