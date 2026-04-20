alias Pathfinder.Repo
alias Pathfinder.Routes.{City, Route, RouteScore}
alias Pathfinder.Disruption.DisruptionZone
alias Pathfinder.Scoring
alias Pathfinder.CitySlug

now = DateTime.utc_now() |> DateTime.truncate(:second)
reviewed = DateTime.add(now, -2 * 86_400, :second)
initial_freshness = "current"

upsert_city = fn attrs ->
  attrs = Map.put(attrs, :slug, CitySlug.from_name(attrs.name))

  case Repo.get_by(City, name: attrs.name) do
    nil -> Repo.insert!(City.changeset(%City{}, Map.put(attrs, :is_active, true)))
    existing -> Repo.update!(City.changeset(existing, Map.put(attrs, :is_active, true)))
  end
end

upsert_route = fn attrs ->
  case Repo.get_by(Route,
    origin_city_id: attrs.origin_city_id,
    destination_city_id: attrs.destination_city_id,
    route_name: attrs.route_name
  ) do
    nil -> Repo.insert!(Route.changeset(%Route{}, attrs))
    existing -> Repo.update!(Route.changeset(existing, attrs))
  end
end

upsert_score = fn route, score_attrs ->
  calc = Scoring.calculate(
    score_attrs.airspace_score,
    score_attrs.corridor_score,
    score_attrs.hub_score,
    score_attrs.complexity_score,
    score_attrs.operational_score
  )

  full_attrs =
    score_attrs
    |> Map.put(:structural_score, calc.structural_score)
    |> Map.put(:pressure_score, calc.pressure_score)
    |> Map.put(:composite_score, calc.composite_score)
    |> Map.put(:label, calc.label)
    |> Map.put(:score_cap_reason, calc.score_cap_reason)
    |> Map.put(:freshness_state, initial_freshness)

  case Repo.get_by(RouteScore, route_id: route.id) do
    nil -> Repo.insert!(RouteScore.changeset(%RouteScore{}, Map.put(full_attrs, :route_id, route.id)))
    existing -> Repo.update!(RouteScore.changeset(existing, full_attrs))
  end
end

line = fn coords -> %{"type" => "LineString", "coordinates" => coords} end

lhr = upsert_city.(%{name: "London", country: "United Kingdom", iata_codes: ["LHR","LGW"], lat: 51.477, lng: -0.461})
ist = upsert_city.(%{name: "Istanbul", country: "Turkey", iata_codes: ["IST"], lat: 40.976, lng: 28.816})
dxb = upsert_city.(%{name: "Dubai", country: "UAE", iata_codes: ["DXB"], lat: 25.253, lng: 55.364})
hkg = upsert_city.(%{name: "Hong Kong", country: "China SAR", iata_codes: ["HKG"], lat: 22.309, lng: 113.915})
bkk = upsert_city.(%{name: "Bangkok", country: "Thailand", iata_codes: ["BKK"], lat: 13.681, lng: 100.747})
sin = upsert_city.(%{name: "Singapore", country: "Singapore", iata_codes: ["SIN"], lat: 1.359, lng: 103.989})

Enum.each(Pathfinder.Disruption.ZoneDefinitions.all(), fn attrs ->
  case Repo.get_by(DisruptionZone, slug: attrs.slug) do
    nil -> Repo.insert!(DisruptionZone.changeset(%DisruptionZone{}, attrs))
    existing -> Repo.update!(DisruptionZone.changeset(existing, attrs))
  end
end)

route =
  upsert_route.(%{
    origin_city_id: lhr.id,
    destination_city_id: bkk.id,
    via_hub_city_id: ist.id,
    corridor_family: "turkey_hub",
    route_name: "Via Istanbul",
    carrier_notes: "Turkish Airlines (TK)",
    path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
    distance_km: 9430,
    typical_duration_minutes: 690,
    is_active: true,
    last_reviewed_at: reviewed
  })

upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best current option for London to Bangkok.",
  ranking_context: "Avoids the active Middle East advisory zone on both legs.",
  watch_for: "Monitor Istanbul operations before departure.",
  explanation_bullets: ["Avoids the active Middle East advisory zone on both legs."],
  calculated_at: now
})

route =
  upsert_route.(%{
    origin_city_id: lhr.id,
    destination_city_id: bkk.id,
    via_hub_city_id: dxb.id,
    corridor_family: "gulf_dubai",
    route_name: "Via Dubai",
    carrier_notes: "Emirates (EK)",
    path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
    distance_km: 10100,
    typical_duration_minutes: 750,
    is_active: true,
    last_reviewed_at: reviewed
  })

upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency option, but the Europe-to-Gulf leg crosses the active advisory zone.",
  ranking_context: "Ranks below Istanbul because the London–Dubai leg crosses the active advisory zone.",
  watch_for: "Monitor regional escalation around the Gulf.",
  explanation_bullets: ["The London–Dubai leg crosses the active advisory zone."],
  calculated_at: now
})

route =
  upsert_route.(%{
    origin_city_id: lhr.id,
    destination_city_id: bkk.id,
    via_hub_city_id: hkg.id,
    corridor_family: "north_asia_hkg",
    route_name: "Via Hong Kong",
    carrier_notes: "Cathay Pacific (CX)",
    path_geojson: line.([[lhr.lng, lhr.lat], [52.0, 46.0], [85.0, 43.0], [hkg.lng, hkg.lat], [bkk.lng, bkk.lat]]),
    distance_km: 11800,
    typical_duration_minutes: 820,
    is_active: true,
    last_reviewed_at: reviewed
  })

upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Avoids Gulf and Middle East completely, but total journey is longer.",
  ranking_context: "Same clean airspace story as Istanbul, but more structural drag.",
  watch_for: "Monitor Central Asian corridor flow restrictions.",
  explanation_bullets: ["Avoids the Middle East advisory zone entirely on both legs."],
  calculated_at: now
})

route =
  upsert_route.(%{
    origin_city_id: lhr.id,
    destination_city_id: sin.id,
    via_hub_city_id: ist.id,
    corridor_family: "turkey_hub",
    route_name: "Via Istanbul",
    carrier_notes: "Turkish Airlines (TK)",
    path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
    distance_km: 11190,
    typical_duration_minutes: 810,
    is_active: true,
    last_reviewed_at: reviewed
  })

upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for London to Singapore.",
  ranking_context: "Avoids the advisory zone on both legs.",
  watch_for: "Monitor any Iranian FIR changes on the second leg.",
  explanation_bullets: ["Avoids the advisory zone on both legs."],
  calculated_at: now
})

route =
  upsert_route.(%{
    origin_city_id: lhr.id,
    destination_city_id: sin.id,
    via_hub_city_id: dxb.id,
    corridor_family: "gulf_dubai",
    route_name: "Via Dubai",
    carrier_notes: "Emirates (EK)",
    path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
    distance_km: 11870,
    typical_duration_minutes: 855,
    is_active: true,
    last_reviewed_at: reviewed
  })

upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Reliable option with high frequency, but the London–Dubai leg crosses the active advisory zone.",
  ranking_context: "Ranks behind Istanbul because the first leg crosses the active advisory zone.",
  watch_for: "Monitor Gulf escalation closely.",
  explanation_bullets: ["The London–Dubai leg crosses the active advisory zone."],
  calculated_at: now
})

route =
  upsert_route.(%{
    origin_city_id: lhr.id,
    destination_city_id: sin.id,
    via_hub_city_id: hkg.id,
    corridor_family: "north_asia_hkg",
    route_name: "Via Hong Kong",
    carrier_notes: "Cathay Pacific (CX)",
    path_geojson: line.([[lhr.lng, lhr.lat], [52.0, 46.0], [85.0, 43.0], [hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
    distance_km: 12600,
    typical_duration_minutes: 890,
    is_active: true,
    last_reviewed_at: reviewed
  })

upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Gulf-free routing via Hong Kong. Longer total journey but cleaner airspace profile than Gulf-connected options.",
  ranking_context: "Avoids the advisory zone on all legs but carries more structural drag than Istanbul.",
  watch_for: "Monitor Central Asian corridor flow restrictions.",
  explanation_bullets: ["Avoids the advisory zone on all legs."],
  calculated_at: now
})

IO.puts("SEED_LIVE_DONE")
