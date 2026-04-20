defmodule Pathfinder.Routes do
  import Ecto.Query
  alias Pathfinder.{Repo, RouteCache}
  alias Pathfinder.Routes.{City, Route, RouteScore}

  # --- City queries ---

  def list_active_cities do
    City
    |> where([c], c.is_active == true)
    |> order_by([c], c.name)
    |> Repo.all()
  end

  def search_cities(query) when byte_size(query) < 2, do: []

  def search_cities(query) do
    term = "%#{String.downcase(query)}%"

    City
    |> where([c], c.is_active == true)
    |> where([c], like(fragment("lower(?)", c.name), ^term) or like(fragment("lower(?)", c.country), ^term))
    |> order_by([c], c.name)
    |> limit(8)
    |> Repo.all()
  end

  def get_city!(id), do: Repo.get!(City, id)

  def get_city_by_name(name) do
    City
    |> where([c], fragment("lower(?)", c.name) == ^String.downcase(name))
    |> Repo.one()
  end

  def get_city_by_slug(slug) do
    City
    |> where([c], c.slug == ^slug)
    |> Repo.one()
  end

  # Returns all unique (origin, destination) city name pairs with active routes.
  # Used by the sitemap to generate canonical pair URLs.
  # Cached: called on every search mount via featured_route_pairs/0.
  def active_city_pairs do
    RouteCache.fetch(:active_city_pairs, 300, fn ->
      from(r in Route,
        join: oc in City, on: oc.id == r.origin_city_id,
        join: dc in City, on: dc.id == r.destination_city_id,
        where: r.is_active == true,
        distinct: true,
        select: {oc.name, dc.name},
        order_by: [asc: oc.name, asc: dc.name]
      )
      |> Repo.all()
    end)
  end

  # Returns all cities that have at least one active outbound route.
  # Used by the sitemap and from-city hub pages.
  def active_origin_cities do
    from(c in City,
      join: r in Route, on: r.origin_city_id == c.id,
      where: r.is_active == true and c.is_active == true,
      distinct: true,
      order_by: c.name
    )
    |> Repo.all()
  end

  # Returns all cities that have at least one active inbound route.
  # Used by the sitemap and to-city hub pages.
  def active_destination_cities do
    from(c in City,
      join: r in Route, on: r.destination_city_id == c.id,
      where: r.is_active == true and c.is_active == true,
      distinct: true,
      order_by: c.name
    )
    |> Repo.all()
  end

  # Returns {origin_city, best_route} pairs for all active routes to a city,
  # sorted by best composite score descending.
  # Cached per city_id: hub pages are frequently revisited and the data is stable.
  # via_hub_city omitted — city hub pages display city name and score only.
  def origins_to_city(city_id) do
    RouteCache.fetch({:origins_to_city, city_id}, 300, fn ->
      Route
      |> where([r], r.destination_city_id == ^city_id and r.is_active == true)
      |> preload([:origin_city, :destination_city, score: []])
      |> Repo.all()
      |> Enum.group_by(& &1.origin_city_id)
      |> Enum.map(fn {_origin_id, routes} ->
        best = best_route(routes)
        {best && best.origin_city, best}
      end)
      |> Enum.reject(fn {city, best} -> is_nil(city) or is_nil(best) end)
      |> Enum.sort_by(fn {_city, best} -> {-best.score.composite_score, raw_float(best.score)} end)
    end)
  end

  # Returns {destination_city, best_route} pairs for all active routes from a city,
  # sorted by best composite score descending.
  # Cached per city_id: hub pages are frequently revisited and the data is stable.
  # via_hub_city omitted — city hub pages display city name and score only.
  def destinations_from_city(city_id) do
    RouteCache.fetch({:destinations_from_city, city_id}, 300, fn ->
      Route
      |> where([r], r.origin_city_id == ^city_id and r.is_active == true)
      |> preload([:origin_city, :destination_city, score: []])
      |> Repo.all()
      |> Enum.group_by(& &1.destination_city_id)
      |> Enum.map(fn {_dest_id, routes} ->
        best = best_route(routes)
        {best && best.destination_city, best}
      end)
      |> Enum.reject(fn {city, best} -> is_nil(city) or is_nil(best) end)
      |> Enum.sort_by(fn {_city, best} -> {-best.score.composite_score, raw_float(best.score)} end)
    end)
  end

  # --- Route queries ---

  # Cached per (origin_id, destination_id): the most frequently repeated query in the app.
  # Every results page and route detail page fires this. TTL 10 minutes — safe because
  # scores only change via deliberate seed or operator action.
  def find_routes(origin_id, destination_id) do
    RouteCache.fetch({:find_routes, origin_id, destination_id}, 600, fn ->
      Route
      |> where([r], r.origin_city_id == ^origin_id and r.destination_city_id == ^destination_id)
      |> where([r], r.is_active == true)
      |> preload([:origin_city, :destination_city, :via_hub_city, score: [], disruption_factors: [:disruption_zone]])
      |> Repo.all()
      |> sort_by_score()
    end)
  end

  def find_routes_bidirectional(origin_id, destination_id) do
    routes = find_routes(origin_id, destination_id)

    if Enum.empty?(routes) do
      find_routes(destination_id, origin_id)
    else
      routes
    end
  end

  def get_route!(id) do
    RouteCache.fetch({:route_by_id, id}, 600, fn ->
      Route
      |> preload([:origin_city, :destination_city, :via_hub_city, score: [], disruption_factors: [:disruption_zone]])
      |> Repo.get!(id)
    end)
  end

  def routes_for_pair?(origin_id, destination_id) do
    Route
    |> where([r], r.origin_city_id == ^origin_id and r.destination_city_id == ^destination_id)
    |> where([r], r.is_active == true)
    |> Repo.exists?()
  end

  def active_route_count do
    Route
    |> where([r], r.is_active == true)
    |> Repo.aggregate(:count, :id)
  end

  # --- Score helpers ---

  def best_route(routes) do
    scored = Enum.filter(routes, & &1.score)

    # Always prefer a route with no active advisory exposure (airspace_score <= 1)
    # over routes that transit an active advisory or conflict zone.
    # Only fall back to advisory-zone routes when no clean alternative exists.
    clean = Enum.filter(scored, & &1.score.airspace_score <= 1)

    if Enum.empty?(clean) do
      Enum.max_by(scored, fn r -> {r.score.composite_score, -raw_float(r.score)} end, fn -> nil end)
    else
      Enum.max_by(clean, fn r -> {r.score.composite_score, -raw_float(r.score)} end, fn -> nil end)
    end
  end

  def routes_as_map_features(routes) do
    routes
    |> Enum.filter(& &1.score)
    |> Enum.map(fn route ->
      %{
        id: route.id,
        route_name: route.route_name,
        label: route.score.label,
        color: RouteScore.map_color(route.score.label),
        composite_score: route.score.composite_score,
        geojson: route.path_geojson,
        corridor_family: route.corridor_family,
        airspace_score: route.score.airspace_score
      }
    end)
  end

  def list_active_routes_for_sitemap do
    Route
    |> where([r], r.is_active == true)
    |> select([r], %{id: r.id})
    |> Repo.all()
  end

  # --- Popular routes for home screen ---

  # Flat list for sitemap generation and legacy use.
  # Any pair not present in active DB routes is automatically filtered out.
  @preferred_preset_pairs [
    {"London",       "Bangkok"},    {"Bangkok",      "London"},
    {"London",       "Singapore"},  {"Singapore",    "London"},
    {"Frankfurt",    "Bangkok"},    {"Bangkok",      "Frankfurt"},
    {"Paris",        "Bangkok"},    {"Bangkok",      "Paris"},
    {"Amsterdam",    "Bangkok"},    {"Bangkok",      "Amsterdam"},
    {"Frankfurt",    "Singapore"},  {"Singapore",    "Frankfurt"},
    {"Paris",        "Singapore"},  {"Singapore",    "Paris"},
    {"Amsterdam",    "Singapore"},  {"Singapore",    "Amsterdam"},
    {"London",       "Kuala Lumpur"},{"Kuala Lumpur", "London"},
    {"Amsterdam",    "Kuala Lumpur"},{"Kuala Lumpur", "Amsterdam"},
    {"Jakarta",      "Amsterdam"},  {"Jakarta",      "London"},
    {"Jakarta",      "Paris"},      {"Jakarta",      "Frankfurt"},
    {"London",       "Jakarta"},    {"Amsterdam",    "Jakarta"},
    {"Frankfurt",    "Jakarta"},    {"Paris",        "Jakarta"},
    {"Jakarta",      "Tokyo"},      {"Tokyo",        "Jakarta"},
    {"Jakarta",      "Seoul"},      {"Seoul",        "Jakarta"},
    {"Jakarta",      "Singapore"},  {"Singapore",    "Jakarta"},
    {"Jakarta",      "Bangkok"},    {"Bangkok",      "Jakarta"},
    {"London",       "Tokyo"},      {"Tokyo",        "London"},
    {"Frankfurt",    "Tokyo"},      {"Tokyo",        "Frankfurt"},
    {"Paris",        "Tokyo"},      {"Tokyo",        "Paris"},
    {"Amsterdam",    "Tokyo"},      {"Tokyo",        "Amsterdam"},
    {"London",       "Seoul"},      {"Seoul",        "London"},
    {"Frankfurt",    "Seoul"},      {"Seoul",        "Frankfurt"},
    {"Amsterdam",    "Seoul"},      {"Seoul",        "Amsterdam"},
    {"Paris",        "Seoul"},      {"Seoul",        "Paris"},
    {"London",       "Hong Kong"},  {"Hong Kong",    "London"},
    {"Frankfurt",    "Hong Kong"},  {"Hong Kong",    "Frankfurt"},
    {"Amsterdam",    "Hong Kong"},  {"Hong Kong",    "Amsterdam"},
    {"Paris",        "Hong Kong"},  {"Hong Kong",    "Paris"},
    {"London",       "Delhi"},      {"Delhi",        "London"},
    {"Frankfurt",    "Delhi"},      {"Delhi",        "Frankfurt"},
    {"Amsterdam",    "Delhi"},      {"Delhi",        "Amsterdam"},
    {"Paris",        "Delhi"},      {"Delhi",        "Paris"},
    {"London",       "Mumbai"},     {"Mumbai",       "London"},
    {"Frankfurt",    "Mumbai"},     {"Mumbai",       "Frankfurt"},
    {"Amsterdam",    "Mumbai"},     {"Mumbai",       "Amsterdam"},
    {"Paris",        "Mumbai"},     {"Mumbai",       "Paris"},
    {"London",       "Dubai"},      {"Dubai",        "London"},
    {"Dubai",        "Singapore"},  {"Singapore",    "Dubai"},
    {"Dubai",        "Bangkok"},    {"Bangkok",      "Dubai"},
    {"Dubai",        "Mumbai"},     {"Mumbai",       "Dubai"},
    {"Dubai",        "Delhi"},      {"Delhi",        "Dubai"},
    {"Hong Kong",    "Delhi"},      {"Delhi",        "Hong Kong"},
    {"Delhi",        "Tokyo"},      {"Tokyo",        "Delhi"},
    {"Mumbai",       "Seoul"},      {"Seoul",        "Mumbai"},
    {"Kuala Lumpur", "Seoul"},      {"Seoul",        "Kuala Lumpur"},
    {"Delhi",        "Singapore"},  {"Delhi",        "Bangkok"},
    {"Mumbai",       "Singapore"},  {"Mumbai",       "Bangkok"},
    {"Singapore",    "Delhi"},      {"Singapore",    "Mumbai"},
    {"Bangkok",      "Delhi"},      {"Bangkok",      "Mumbai"},
    {"Bangkok",      "Hong Kong"},  {"Tokyo",        "Singapore"},
    {"Singapore",    "Tokyo"},      {"Singapore",    "Seoul"},
    {"Seoul",        "Singapore"},  {"Hong Kong",    "Bangkok"},
    {"Hong Kong",    "Singapore"},  {"Bangkok",      "Singapore"},
    {"Singapore",    "Bangkok"},    {"Hong Kong",    "Seoul"},
    {"Seoul",        "Hong Kong"},  {"Bangkok",      "Seoul"},
    {"Seoul",        "Bangkok"},    {"Bangkok",      "Tokyo"},
    {"Tokyo",        "Bangkok"},    {"Delhi",        "Seoul"},
    {"Seoul",        "Delhi"},      {"Sydney",       "London"},
    {"London",       "Sydney"},     {"Madrid",       "Singapore"},
    {"Madrid",       "Bangkok"},    {"Madrid",       "Hong Kong"},
    {"Sydney",       "Frankfurt"},  {"Frankfurt",    "Kuala Lumpur"},
    {"Kuala Lumpur", "Frankfurt"},  {"Paris",        "Kuala Lumpur"},
    {"Kuala Lumpur", "Paris"},
    {"Munich",       "Bangkok"},    {"Bangkok",      "Munich"},
    {"Munich",       "Singapore"},  {"Singapore",    "Munich"},
    {"Rome",         "Bangkok"},    {"Bangkok",      "Rome"},
    {"Rome",         "Singapore"},  {"Singapore",    "Rome"},
    {"Zurich",       "Bangkok"},    {"Bangkok",      "Zurich"},
    {"Zurich",       "Singapore"},  {"Singapore",    "Zurich"},
    # North America
    {"New York",     "Delhi"},      {"New York",     "Dubai"},
    {"Toronto",      "Delhi"},      {"Toronto",      "London"},
    {"Los Angeles",  "Tokyo"},      {"Vancouver",    "Tokyo"},
    # Europe → China destination
    {"London",       "Beijing"},    {"Frankfurt",    "Shanghai"},
  ]

  # Grouped preset structure for the homepage tab UI.
  # Groups are ordered by product priority: highest Iran/advisory relevance first.
  # Any pair not in the active DB is silently filtered — never shows an empty chip.
  @grouped_preset_pairs [
    {"Europe ↔ Southeast Asia", [
      {"London",       "Bangkok"},    {"Bangkok",      "London"},
      {"London",       "Singapore"},  {"Singapore",    "London"},
      {"Frankfurt",    "Bangkok"},    {"Bangkok",      "Frankfurt"},
      {"Paris",        "Bangkok"},    {"Amsterdam",    "Bangkok"},
      {"Frankfurt",    "Singapore"},  {"Amsterdam",    "Singapore"},
      {"Paris",        "Singapore"},  {"London",       "Kuala Lumpur"},
      {"Kuala Lumpur", "London"},     {"Bangkok",      "Amsterdam"},
      {"Bangkok",      "Paris"},      {"Singapore",    "Amsterdam"},
      {"Frankfurt",    "Kuala Lumpur"},{"Kuala Lumpur", "Frankfurt"},
      {"Paris",        "Kuala Lumpur"},{"Kuala Lumpur", "Paris"},
      {"London",       "Jakarta"},    {"Jakarta",      "London"},
      {"Amsterdam",    "Jakarta"},    {"Jakarta",      "Amsterdam"},
      {"Frankfurt",    "Jakarta"},    {"Jakarta",      "Frankfurt"},
      {"Paris",        "Jakarta"},    {"Jakarta",      "Paris"},
    ]},
    {"Europe ↔ East Asia & China", [
      {"London",       "Tokyo"},      {"Tokyo",        "London"},
      {"London",       "Seoul"},      {"Seoul",        "London"},
      {"Frankfurt",    "Tokyo"},      {"Tokyo",        "Frankfurt"},
      {"Frankfurt",    "Seoul"},      {"Seoul",        "Frankfurt"},
      {"Paris",        "Tokyo"},      {"Amsterdam",    "Seoul"},
      {"Amsterdam",    "Tokyo"},      {"Seoul",        "Amsterdam"},
      {"London",       "Hong Kong"},  {"Hong Kong",    "London"},
      {"Frankfurt",    "Hong Kong"},  {"Hong Kong",    "Frankfurt"},
      {"Tokyo",        "Paris"},      {"Seoul",        "Paris"},
      {"London",       "Beijing"},    {"Frankfurt",    "Shanghai"},
    ]},
    {"Gulf & South Asia", [
      {"London",       "Dubai"},      {"Dubai",        "London"},
      {"Dubai",        "Singapore"},  {"Singapore",    "Dubai"},
      {"Dubai",        "Bangkok"},    {"Bangkok",      "Dubai"},
      {"Dubai",        "Mumbai"},     {"Mumbai",       "Dubai"},
      {"Dubai",        "Delhi"},      {"Delhi",        "Dubai"},
      {"London",       "Delhi"},      {"Delhi",        "London"},
      {"London",       "Mumbai"},     {"Mumbai",       "London"},
      {"Frankfurt",    "Delhi"},      {"Delhi",        "Frankfurt"},
      {"Amsterdam",    "Delhi"},      {"Delhi",        "Amsterdam"},
      {"Frankfurt",    "Mumbai"},     {"Mumbai",       "Frankfurt"},
      {"Delhi",        "Paris"},      {"Mumbai",       "Paris"},
    ]},
    {"North America", [
      {"New York",    "Delhi"},      {"New York",    "Dubai"},
      {"Toronto",     "Delhi"},      {"Toronto",     "London"},
      {"Los Angeles", "Tokyo"},      {"Vancouver",   "Tokyo"},
    ]},
    {"Intra-Asia", [
      {"Singapore",    "Tokyo"},      {"Tokyo",        "Bangkok"},
      {"Bangkok",      "Tokyo"},      {"Seoul",        "Singapore"},
      {"Singapore",    "Seoul"},      {"Bangkok",      "Seoul"},
      {"Seoul",        "Bangkok"},    {"Hong Kong",    "Bangkok"},
      {"Hong Kong",    "Singapore"},  {"Bangkok",      "Singapore"},
      {"Singapore",    "Bangkok"},    {"Seoul",        "Hong Kong"},
      {"Hong Kong",    "Seoul"},      {"Hong Kong",    "Delhi"},
      {"Delhi",        "Hong Kong"},  {"Delhi",        "Seoul"},
      {"Seoul",        "Delhi"},      {"Delhi",        "Tokyo"},
      {"Tokyo",        "Delhi"},      {"Mumbai",       "Seoul"},
      {"Seoul",        "Mumbai"},     {"Kuala Lumpur", "Seoul"},
      {"Seoul",        "Kuala Lumpur"},{"Delhi",       "Singapore"},
      {"Mumbai",       "Singapore"},  {"Delhi",        "Bangkok"},
      {"Mumbai",       "Bangkok"},    {"Singapore",    "Delhi"},
      {"Singapore",    "Mumbai"},     {"Bangkok",      "Delhi"},
      {"Bangkok",      "Mumbai"},     {"Bangkok",      "Hong Kong"},
      {"Tokyo",        "Singapore"},  {"Jakarta",      "Tokyo"},
      {"Tokyo",        "Jakarta"},    {"Jakarta",      "Seoul"},
      {"Seoul",        "Jakarta"},    {"Jakarta",      "Singapore"},
      {"Singapore",    "Jakarta"},    {"Jakarta",      "Bangkok"},
      {"Bangkok",      "Jakarta"},
    ]},
  ]

  # Routes where the corridor choice creates meaningfully different advisory exposure.
  # These are pairs with 3+ corridors via Gulf/Turkey/SE Asia — the routes where
  # via Dubai vs via Istanbul vs direct produces different airspace scores.
  # Ordered by traffic weight and advisory relevance. Kept short intentionally.
  #
  # Curation principles (launch set):
  #   - Core EU→SEA anchors (London/Frankfurt × Bangkok/Singapore)
  #   - East Asia depth: Tokyo, Seoul, Hong Kong — corridors matter here too
  #   - India pairs: Delhi/Mumbai — large market, strong Central Asian vs Gulf story
  #   - Reverse pairs: Asia→Europe — demonstrates two-directional product value
  #   - Excluded: secondary EU cities (Munich, Rome, Zurich) — kept in presets only
  @featured_route_pairs [
    # EU → Southeast Asia
    {"London",    "Bangkok"},
    {"London",    "Singapore"},
    {"Frankfurt", "Bangkok"},
    {"Frankfurt", "Singapore"},
    # EU → East Asia
    {"London",    "Tokyo"},
    {"London",    "Seoul"},
    {"Frankfurt", "Tokyo"},
    {"Frankfurt", "Hong Kong"},
    {"Amsterdam", "Singapore"},
    # EU → India
    {"London",    "Delhi"},
    {"Frankfurt", "Delhi"},
    {"Paris",     "Bangkok"},
    # EU → China destination
    {"London",    "Beijing"},
    {"Frankfurt", "Shanghai"},
    # North America → India (strong corridor story)
    {"New York",  "Delhi"},
    {"Toronto",   "Delhi"},
    # Asia → Europe (reverse pairs)
    {"Singapore", "London"},
    {"Bangkok",   "London"},
    {"Tokyo",     "London"},
    {"Delhi",     "London"},
    {"Seoul",     "London"},
    {"Mumbai",    "London"},
  ]

  def featured_route_pairs do
    active_set = active_city_pairs() |> MapSet.new()

    @featured_route_pairs
    |> Enum.filter(fn {o, d} -> MapSet.member?(active_set, {o, d}) end)
    |> Enum.map(fn {o, d} -> %{label: "#{o} → #{d}", origin: o, destination: d} end)
  end

  # Builds the home-page preset list (flat, for sitemap / legacy callers).
  def popular_route_pairs do
    active_set = active_city_pairs() |> MapSet.new()

    @preferred_preset_pairs
    |> Enum.filter(fn {origin, dest} -> MapSet.member?(active_set, {origin, dest}) end)
    |> Enum.uniq()
    |> Enum.map(fn {origin, dest} ->
      %{label: "#{origin} → #{dest}", origin: origin, destination: dest}
    end)
  end

  # Returns grouped presets filtered against active DB pairs.
  # Each group is {group_name, [%{label, origin, destination}]}.
  # Empty groups are excluded so the UI never shows a tab with nothing in it.
  def grouped_popular_pairs do
    active_set = active_city_pairs() |> MapSet.new()

    @grouped_preset_pairs
    |> Enum.map(fn {group_name, pairs} ->
      covered =
        pairs
        |> Enum.filter(fn {o, d} -> MapSet.member?(active_set, {o, d}) end)
        |> Enum.map(fn {o, d} -> %{label: "#{o} → #{d}", origin: o, destination: d} end)

      {group_name, covered}
    end)
    |> Enum.reject(fn {_name, pairs} -> Enum.empty?(pairs) end)
  end

  # Returns the distinct corridor families present in a route list.
  # Used to enforce the "minimum 3 corridor families" recommendation rule.
  def corridor_families(routes) do
    routes
    |> Enum.map(& &1.corridor_family)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def sufficient_corridor_coverage?(routes) do
    length(corridor_families(routes)) >= 3
  end

  # Returns nearby covered pairs for the not-covered state.
  # Finds: (a) other destinations reachable from the same origin,
  #         (b) other origins that serve the same destination.
  # Limited to 5 each so the suggestions section stays compact.
  def nearby_covered_pairs(origin_city_id, dest_city_id) do
    from_origin =
      Route
      |> where([r], r.origin_city_id == ^origin_city_id)
      |> where([r], r.destination_city_id != ^dest_city_id)
      |> where([r], r.is_active == true)
      |> preload([:destination_city, score: []])
      |> Repo.all()
      |> Enum.group_by(& &1.destination_city_id)
      |> Enum.map(fn {_id, routes} ->
        best = best_route(routes)
        city = best && best.destination_city
        %{city_name: city.name, city_slug: city.slug, direction: :destination, score: best.score}
      end)
      |> Enum.sort_by(fn %{score: s} -> -(s && s.composite_score || 0) end)
      |> Enum.take(5)

    to_dest =
      Route
      |> where([r], r.destination_city_id == ^dest_city_id)
      |> where([r], r.origin_city_id != ^origin_city_id)
      |> where([r], r.is_active == true)
      |> preload([:origin_city, score: []])
      |> Repo.all()
      |> Enum.group_by(& &1.origin_city_id)
      |> Enum.map(fn {_id, routes} ->
        best = best_route(routes)
        city = best && best.origin_city
        %{city_name: city.name, city_slug: city.slug, direction: :origin, score: best.score}
      end)
      |> Enum.sort_by(fn %{score: s} -> -(s && s.composite_score || 0) end)
      |> Enum.take(5)

    %{from_origin: from_origin, to_destination: to_dest}
  end

  defp sort_by_score(routes) do
    Enum.sort_by(routes, fn r ->
      if r.score,
        # Primary: composite_score descending. Tiebreaker: raw_float ascending
        # (lower pre-rounding disruption weight surfaces first among equal composites).
        do: {r.score.composite_score, -raw_float(r.score)},
        else: {0, 0.0}
    end, :desc)
  end

  # Continuous disruption weight from raw integer inputs before any rounding.
  # Mirrors the weighted-input formula in Scoring.calculate/5.
  # Lower = less disruption = preferred when composite_scores are equal.
  defp raw_float(score) do
    (score.corridor_score * 0.45 + score.hub_score * 0.35 + score.complexity_score * 0.20) * 0.50 +
    (score.airspace_score * 0.70 + score.operational_score * 0.30) * 0.50
  end
end
