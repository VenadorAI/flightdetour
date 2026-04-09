defmodule Pathfinder.RoutesTest do
  use Pathfinder.DataCase

  alias Pathfinder.{Repo, Routes}
  alias Pathfinder.Routes.{City, Route, RouteScore}

  # ──────────────────────────────────────────────────────────────────────────────
  # Test fixture helpers
  # ──────────────────────────────────────────────────────────────────────────────

  defp insert_city(name, attrs \\ %{}) do
    defaults = %{name: name, country: "Testland", lat: 0.0, lng: 0.0, is_active: true}
    %City{} |> City.changeset(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  defp insert_route(origin, destination, attrs \\ %{}) do
    defaults = %{
      route_name: "#{origin.name} → #{destination.name} via Test",
      path_geojson: %{"type" => "LineString", "coordinates" => [[0, 0], [1, 1]]},
      is_active: true,
      corridor_family: "direct"
    }
    %Route{}
    |> Route.changeset(
      defaults
      |> Map.merge(attrs)
      |> Map.merge(%{origin_city_id: origin.id, destination_city_id: destination.id})
    )
    |> Repo.insert!()
  end

  # Inserts a route_score with explicit composite/airspace values.
  # All other score fields default to sensible values so the test focuses on
  # only the dimensions it actually cares about.
  defp insert_score(route, composite, airspace, label \\ nil) do
    effective_label = label || Pathfinder.Scoring.label_for(composite)

    %RouteScore{}
    |> RouteScore.changeset(%{
      route_id: route.id,
      airspace_score: airspace,
      corridor_score: 0,
      hub_score: 0,
      complexity_score: 0,
      operational_score: 0,
      structural_score: composite,
      pressure_score: composite,
      composite_score: composite,
      label: effective_label,
      calculated_at: ~U[2026-03-01 00:00:00Z]
    })
    |> Repo.insert!()
  end

  defp reload(route), do: Repo.preload(route, [:score], force: true)

  # ──────────────────────────────────────────────────────────────────────────────
  # best_route/1
  # ──────────────────────────────────────────────────────────────────────────────

  describe "best_route/1" do
    setup do
      origin = insert_city("Origin")
      dest = insert_city("Destination")
      {:ok, origin: origin, dest: dest}
    end

    test "prefers clean route (airspace ≤ 1) over advisory route even when advisory has higher composite",
         %{origin: o, dest: d} do
      advisory_route = insert_route(o, d, %{route_name: "Via Gulf (advisory)"})
      clean_route = insert_route(o, d, %{route_name: "Via Istanbul (clean)"})

      insert_score(advisory_route, 65, 2)
      insert_score(clean_route, 60, 1)

      routes = [reload(advisory_route), reload(clean_route)]
      best = Routes.best_route(routes)

      assert best.id == clean_route.id
    end

    test "picks highest-composite clean route when multiple clean options exist",
         %{origin: o, dest: d} do
      r1 = insert_route(o, d, %{route_name: "Clean A"})
      r2 = insert_route(o, d, %{route_name: "Clean B"})

      insert_score(r1, 70, 0)
      insert_score(r2, 80, 1)

      routes = [reload(r1), reload(r2)]
      best = Routes.best_route(routes)

      assert best.id == r2.id
    end

    test "falls back to advisory-zone route when no clean alternatives exist",
         %{origin: o, dest: d} do
      advisory_a = insert_route(o, d, %{route_name: "Via Gulf A"})
      advisory_b = insert_route(o, d, %{route_name: "Via Gulf B"})

      insert_score(advisory_a, 65, 2)
      insert_score(advisory_b, 55, 2)

      routes = [reload(advisory_a), reload(advisory_b)]
      best = Routes.best_route(routes)

      assert best.id == advisory_a.id
    end

    test "returns nil when given an empty list" do
      assert Routes.best_route([]) == nil
    end

    test "returns nil when no routes have scores" do
      o = insert_city("NoScoreOrigin")
      d = insert_city("NoScoreDest")
      route = insert_route(o, d)
      # No score inserted — preload returns route with score=nil
      result = Routes.best_route([reload(route)])
      assert result == nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # find_routes/2 — inactive routes excluded
  # ──────────────────────────────────────────────────────────────────────────────

  describe "find_routes/2 — inactive routes" do
    test "does not return routes with is_active = false" do
      origin = insert_city("LondonInactive")
      dest = insert_city("MumbaiInactive")

      active = insert_route(origin, dest, %{route_name: "Active route", is_active: true})
      inactive = insert_route(origin, dest, %{route_name: "Stale route", is_active: false})

      insert_score(active, 75, 0)
      insert_score(inactive, 80, 0)

      results = Routes.find_routes(origin.id, dest.id)
      returned_ids = Enum.map(results, & &1.id)

      assert active.id in returned_ids
      refute inactive.id in returned_ids
    end

    test "deactivating a route removes it from results without deleting it" do
      origin = insert_city("DEACTOrigin")
      dest = insert_city("DEACTDest")
      route = insert_route(origin, dest, %{is_active: true})
      insert_score(route, 70, 0)

      assert length(Routes.find_routes(origin.id, dest.id)) == 1

      Repo.update_all(Route, set: [is_active: false])

      assert Routes.find_routes(origin.id, dest.id) == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # find_routes/2 — sort tiebreaker
  # ──────────────────────────────────────────────────────────────────────────────

  describe "find_routes/2 — sort tiebreaker" do
    test "lower airspace exposure surfaces first when composite scores are equal" do
      origin = insert_city("TiebreakerOrigin")
      dest = insert_city("TiebreakerDest")

      clean = insert_route(origin, dest, %{route_name: "Clean (airspace=0)"})
      advisory = insert_route(origin, dest, %{route_name: "Advisory (airspace=2)"})

      insert_score(clean, 65, 0)
      insert_score(advisory, 65, 2)

      [first | _] = Routes.find_routes(origin.id, dest.id)
      assert first.id == clean.id
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Key route pair ranking scenarios
  # ──────────────────────────────────────────────────────────────────────────────

  # These tests create minimal fixtures that model the intended structural scoring
  # for each corridor type. They verify that the ranking algorithm correctly
  # selects the clean-corridor option over higher-nominal-score advisory routes.

  describe "London → Mumbai ranking" do
    test "Istanbul (airspace=1) wins over Gulf hub (airspace=2) even with close composites" do
      london = insert_city("LHR-LondonMUM")
      mumbai = insert_city("BOM-MumbaiLHR")

      ist = insert_route(london, mumbai, %{route_name: "Via Istanbul", corridor_family: "turkey_hub"})
      dxb = insert_route(london, mumbai, %{route_name: "Via Dubai", corridor_family: "gulf_dubai"})

      # Istanbul: near advisory zone but not through it (airspace=1), solid composite
      insert_score(ist, 70, 1)
      # Dubai: transits advisory zone (airspace=2), capped composite
      insert_score(dxb, 65, 2)

      routes = Routes.find_routes(london.id, mumbai.id)
      best = Routes.best_route(routes)

      assert best.id == ist.id
    end
  end

  describe "Amsterdam → Tokyo ranking" do
    test "Seoul (airspace=0) wins over Istanbul (airspace=1) and Gulf (airspace=2)" do
      amsterdam = insert_city("AMS-AmsterdamTYO")
      tokyo = insert_city("TYO-TokyoAMS")

      icn = insert_route(amsterdam, tokyo, %{route_name: "Via Seoul", corridor_family: "north_asia_icn"})
      ist = insert_route(amsterdam, tokyo, %{route_name: "Via Istanbul", corridor_family: "turkey_hub"})
      dxb = insert_route(amsterdam, tokyo, %{route_name: "Via Dubai", corridor_family: "gulf_dubai"})

      insert_score(icn, 70, 0)
      insert_score(ist, 65, 1)
      insert_score(dxb, 65, 2)

      routes = Routes.find_routes(amsterdam.id, tokyo.id)
      best = Routes.best_route(routes)

      assert best.id == icn.id
    end
  end

  describe "Jakarta → Amsterdam ranking" do
    test "Singapore (airspace=0) wins over Gulf hub (airspace=2)" do
      jakarta = insert_city("CGK-JakartaAMS")
      amsterdam = insert_city("AMS-AmsterdamCGK")

      sin = insert_route(jakarta, amsterdam, %{route_name: "Via Singapore", corridor_family: "south_asia_direct"})
      dxb = insert_route(jakarta, amsterdam, %{route_name: "Via Dubai", corridor_family: "gulf_dubai"})

      insert_score(sin, 78, 0)
      insert_score(dxb, 65, 2)

      routes = Routes.find_routes(jakarta.id, amsterdam.id)
      best = Routes.best_route(routes)

      assert best.id == sin.id
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Canonical pair resolver — slug lookup (regression guard for stale-schema bugs)
  # ──────────────────────────────────────────────────────────────────────────────

  describe "get_city_by_slug/1" do
    test "finds city by slug" do
      city = insert_city("SlugCity", %{slug: "slug-city"})
      assert Routes.get_city_by_slug("slug-city").id == city.id
    end

    test "returns nil for unknown slug" do
      assert Routes.get_city_by_slug("nonexistent-slug") == nil
    end

    test "slug field is queryable — no Ecto.QueryError" do
      # This test guards against stale schema compilation where the :slug field
      # is missing from the compiled City module, causing a runtime QueryError.
      insert_city("SlugGuard", %{slug: "slug-guard"})
      result = Routes.get_city_by_slug("slug-guard")
      assert result != nil
      assert result.slug == "slug-guard"
    end
  end

  describe "CitySlug pair resolution end-to-end" do
    test "pair slug round-trips through parse and lookup" do
      alias Pathfinder.CitySlug
      london = insert_city("London E2E", %{slug: "london-e2e"})
      singapore = insert_city("Singapore E2E", %{slug: "singapore-e2e"})
      slug = CitySlug.pair_slug("London E2E", "Singapore E2E")
      assert slug == "london-e2e-to-singapore-e2e"
      {:ok, os, ds} = CitySlug.parse_pair_slug(slug)
      assert Routes.get_city_by_slug(os).id == london.id
      assert Routes.get_city_by_slug(ds).id == singapore.id
    end
  end

  describe "advisory zone routes cannot surface as the top recommendation" do
    test "a clean route with lower composite beats an advisory route regardless of score gap" do
      origin = insert_city("AdvisoryTestOrigin")
      dest = insert_city("AdvisoryTestDest")

      advisory = insert_route(origin, dest, %{route_name: "Advisory (airspace=2, composite=65)"})
      clean = insert_route(origin, dest, %{route_name: "Clean (airspace=1, composite=55)"})

      insert_score(advisory, 65, 2)
      insert_score(clean, 55, 1)

      routes = Routes.find_routes(origin.id, dest.id)
      best = Routes.best_route(routes)

      assert best.id == clean.id
    end
  end
end
