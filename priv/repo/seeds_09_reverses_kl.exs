alias Pathfinder.Repo
alias Pathfinder.Routes.{City, Route, RouteScore}
alias Pathfinder.Scoring
import Ecto.Query

# Load all cities from DB (seeds_00_setup.exs must run first)
c = Enum.into(Repo.all(City), %{}, fn city -> {city.name, city} end)

now      = DateTime.utc_now() |> DateTime.truncate(:second)
reviewed = DateTime.add(now, -2 * 86_400, :second)
initial_freshness = "current"

upsert_route = fn attrs ->
  case Repo.get_by(Route,
    origin_city_id: attrs.origin_city_id,
    destination_city_id: attrs.destination_city_id,
    route_name: attrs.route_name
  ) do
    nil      -> Repo.insert!(Route.changeset(%Route{}, attrs))
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
    s   -> Repo.update!(RouteScore.changeset(s, full_attrs))
  end
end

line = fn coords -> %{"type" => "LineString", "coordinates" => coords} end

lhr = c["London"];   fra = c["Frankfurt"]; ams = c["Amsterdam"];    cdg = c["Paris"]
ist = c["Istanbul"]; dxb = c["Dubai"];     doh = c["Doha"]
sin = c["Singapore"]; bkk = c["Bangkok"]; hkg = c["Hong Kong"]
nrt = c["Tokyo"];   kul = c["Kuala Lumpur"]; del = c["Delhi"];      bom = c["Mumbai"]
icn = c["Seoul"]
cgk = c["Jakarta"]
syd = c["Sydney"]
mad = c["Madrid"]
muc = c["Munich"]
fco = c["Rome"]
zrh = c["Zurich"]
pek = c["Beijing"]
jfk = c["New York"]
lax = c["Los Angeles"]
yyz = c["Toronto"]
yvr = c["Vancouver"]
pvg = c["Shanghai"]

# MISSING REVERSE DIRECTIONS
# ─────────────────────────────────────────────────────────────────────────────

# ─── BANGKOK → DELHI ─────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Thai Airways (TG) / Air India (AI) / IndiGo (6E) · Multiple daily BKK–DEL",
  path_geojson: line.([[bkk.lng, bkk.lat], [86.0, 22.0], [del.lng, del.lat]]),
  distance_km: 2950, typical_duration_minutes: 220, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option. Clean northwestern routing with no advisory exposure and multiple carriers. Thai Airways, Air India, and IndiGo all serve this pair.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, multiple carriers with strong daily frequency.",
  watch_for: "No airspace advisory concerns on this corridor. BKK→DEL routes northwest over Myanmar and into Indian airspace — clean under current conditions.",
  explanation_bullets: [
    "BKK→DEL routes northwest over Myanmar — no advisory zone involvement on this corridor.",
    "Thai Airways, Air India, and IndiGo all serve this pair with multiple daily departures.",
    "At approximately 3.5 hours, disruption is typically resolved within the same day.",
    "Delhi (DEL) has strong hub depth for onward connections throughout India.",
    "No significant airspace routing constraint exists under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: del.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_sin",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) / Air India (AI) · BKK–SIN–DEL",
  path_geojson: line.([[bkk.lng, bkk.lat], [sin.lng, sin.lat], [del.lng, del.lat]]),
  distance_km: 5350, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Via Singapore adds journey time but offers Singapore Airlines quality and Changi's hub depth. Both legs clean. Best when direct is full or SQ is preferred.",
  ranking_context: "Ranks second: same clean airspace but the via-SIN geometry goes southeast then northwest — significant overhead. SQ hub quality is the main draw.",
  watch_for: "No advisory concerns on either segment. SIN→DEL routing is clean; monitor SIN connection time.",
  explanation_bullets: [
    "BKK→SIN first leg is clean; SIN→DEL routes northwest over Bay of Bengal — also clean.",
    "Singapore Airlines operates BKK–SIN–DEL with premium quality and strong frequency.",
    "SIN provides extensive backup connectivity if DEL-bound flights are disrupted.",
    "Approximately 2 hours overhead versus direct BKK–DEL due to southward geometry.",
    "Best for premium travel or when direct BKK–DEL is constrained."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: del.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · BKK–KUL–DEL",
  path_geojson: line.([[bkk.lng, bkk.lat], [kul.lng, kul.lat], [88.0, 12.0], [del.lng, del.lat]]),
  distance_km: 5100, typical_duration_minutes: 415, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Both legs clean. Best when AirAsia X pricing significantly undercuts the direct alternative.",
  ranking_context: "Ranks third: same clean airspace but the KUL routing goes south before heading northwest to Delhi — geometrically roundabout. Budget pricing is the use case.",
  watch_for: "No advisory concerns on either segment. BKK–KUL–DEL is fully clean under current conditions.",
  explanation_bullets: [
    "BKK→KUL first leg clean; KUL→DEL routes northwest over India — no advisory zone.",
    "AirAsia X serves BKK–KUL competitively. Malaysia Airlines continues KUL–DEL.",
    "Total journey approximately 7 hours due to the southward loop geometry.",
    "Best for budget-conscious travel when direct BKK–DEL is expensive.",
    "No advisory concern on either leg under current conditions."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Delhi (3 corridor families: direct, south_asia_sin/SIN, south_asia_kul/KUL)")

# ─── BANGKOK → MUMBAI ────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Thai Airways (TG) / Air India (AI) / IndiGo (6E) · Multiple daily BKK–BOM",
  path_geojson: line.([[bkk.lng, bkk.lat], [86.0, 17.0], [bom.lng, bom.lat]]),
  distance_km: 2800, typical_duration_minutes: 210, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best BKK→BOM option. Clean corridor with no advisory exposure. Thai Airways, Air India, and IndiGo provide strong daily frequency.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, multiple carriers. Under 3.5 hours makes this one of the simplest India–Thailand routes.",
  watch_for: "No airspace advisory concerns on this corridor. BKK→BOM routes southwest over the Bay of Bengal — clean under current conditions.",
  explanation_bullets: [
    "BKK→BOM routes southwest over Myanmar and the Bay of Bengal — no advisory zone involvement.",
    "Thai Airways, Air India, and IndiGo provide multiple daily departures.",
    "At approximately 3.5 hours, same-day rebooking is feasible if disrupted.",
    "Mumbai (BOM) is India's largest aviation hub — strong onward connections.",
    "No routing constraint or advisory concern applies under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: bom.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_sin",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · BKK–SIN–BOM",
  path_geojson: line.([[bkk.lng, bkk.lat], [sin.lng, sin.lat], [bom.lng, bom.lat]]),
  distance_km: 5100, typical_duration_minutes: 415, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Via Singapore offers SQ quality and Changi connectivity. Both legs clean. Best for premium travellers or when direct is full.",
  ranking_context: "Ranks second: equivalent airspace cleanliness, but the southward SIN detour adds ~2 hours versus direct. Premium quality is the draw.",
  watch_for: "No advisory concerns on either segment. SIN→BOM is advisory-clean over the Indian Ocean.",
  explanation_bullets: [
    "BKK→SIN first leg clean; SIN→BOM routes northwest over the Indian Ocean — also clean.",
    "Singapore Airlines offers BKK–SIN–BOM with premium quality and high SIN–BOM frequency.",
    "SIN hub provides extensive backup options if BOM-bound flights are disrupted.",
    "Approximately 2 hours overhead versus direct due to the southward geometry.",
    "Best for premium travel or when direct BKK–BOM is unavailable."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: bom.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · BKK–KUL–BOM",
  path_geojson: line.([[bkk.lng, bkk.lat], [kul.lng, kul.lat], [88.0, 8.0], [bom.lng, bom.lat]]),
  distance_km: 4900, typical_duration_minutes: 400, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Both legs clean. Best when AirAsia X pricing undercuts the direct alternative significantly.",
  ranking_context: "Ranks third: same clean airspace but the KUL routing goes south before heading west to Mumbai. AirAsia X budget fares are the primary use case.",
  watch_for: "No advisory concerns on either segment. BKK–KUL–BOM is fully clean under current conditions.",
  explanation_bullets: [
    "BKK→KUL first leg clean; KUL→BOM routes west over Indian Ocean — no advisory zone.",
    "AirAsia X serves BKK–KUL competitively. Malaysia Airlines continues KUL–BOM.",
    "Total journey approximately 6.5 hours due to the southward geometry.",
    "Best for budget-conscious travel when direct BKK–BOM fares are high.",
    "No advisory concern on either leg under current conditions."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Mumbai (3 corridor families: direct, south_asia_sin/SIN, south_asia_kul/KUL)")

# ─── BANGKOK → HONG KONG ─────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Thai Airways (TG) · 2 daily BKK–HKG; Cathay Pacific (CX) · 2 daily BKK–HKG",
  path_geojson: line.([[bkk.lng, bkk.lat], [hkg.lng, hkg.lat]]),
  distance_km: 1710, typical_duration_minutes: 150, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, well-served short-haul. No advisory zone involvement. Thai Airways and Cathay Pacific together provide 4+ daily departures.",
  ranking_context: "First choice. 2.5-hour hop over South China Sea / Indochina — fully clean. Strong carrier frequency at both hubs.",
  watch_for: "BKK–HKG is advisory-clean. No active EASA or ICAO restrictions. Monitor for weather or Hong Kong terminal disruptions.",
  explanation_bullets: [
    "South China Sea / Indochina corridor is advisory-clean — no active restrictions.",
    "Thai Airways and Cathay Pacific provide 4+ daily departures.",
    "Primary risk is operational disruption at either hub, not airspace.",
    "Hong Kong (HKG) is a strong East Asian hub for onward connections to Japan, Korea, and mainland China."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: hkg.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) / Cathay + SQ · BKK–SIN–HKG",
  path_geojson: line.([[bkk.lng, bkk.lat], [sin.lng, sin.lat], [hkg.lng, hkg.lat]]),
  distance_km: 3010, typical_duration_minutes: 270, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via Singapore hub. Adds ~1.5 hours versus direct. Use when direct BKK–HKG is full or SQ connecting fares are competitive.",
  ranking_context: "Ranked below direct due to added journey time and one-stop complexity. Airspace is fully clean on both legs.",
  watch_for: "BKK–SIN–HKG is clean. Singapore hub is highly reliable; adds approximately 1.5 hours versus direct.",
  explanation_bullets: [
    "Both BKK–SIN and SIN–HKG segments are clean — no advisory zone involvement.",
    "SIN hub provides world-class connections with strong reliability.",
    "Adds ~1.5 hours versus direct due to the southward detour geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Hong Kong (2 corridor families: direct, southeast_asia/SIN)")

# ─── SINGAPORE → DELHI ───────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · daily SIN–DEL; Air India (AI) / IndiGo (6E) · daily SIN–DEL",
  path_geojson: line.([[sin.lng, sin.lat], [90.0, 15.0], [del.lng, del.lat]]),
  distance_km: 4150, typical_duration_minutes: 315, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best SIN→DEL option. Clean northwestward routing with no advisory exposure. Singapore Airlines, Air India, and IndiGo all serve this pair with strong daily frequency.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, multiple carriers give solid rebooking options.",
  watch_for: "No advisory concerns on this corridor. SIN→DEL routes northwest through Bay of Bengal and Indian airspace — clean under current conditions.",
  explanation_bullets: [
    "SIN→DEL routes northwest over the Bay of Bengal and into Indian airspace — no advisory zone involvement.",
    "Singapore Airlines, Air India, and IndiGo provide multiple daily departures.",
    "Direct routing eliminates the risk of a missed connection adding 5–8 hours to the journey.",
    "At approximately 5.5 hours, a clean, well-operated corridor with no current advisory constraints.",
    "Delhi (DEL) is India's busiest airport — strong onward connections throughout the subcontinent."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: del.id, via_hub_city_id: bkk.id,
  corridor_family: "south_asia_bkk",
  route_name: "Via Bangkok",
  carrier_notes: "Thai Airways (TG) · SIN–BKK–DEL · Multiple daily SIN–BKK departures",
  path_geojson: line.([[sin.lng, sin.lat], [bkk.lng, bkk.lat], [del.lng, del.lat]]),
  distance_km: 4650, typical_duration_minutes: 365, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Solid backup via Bangkok hub. SIN–BKK adds a connection but Thai Airways frequency is strong and BKK is well-connected. Both legs clean.",
  ranking_context: "Ranks second: same clean airspace as direct, but Bangkok connection adds schedule risk.",
  watch_for: "No advisory concerns on either segment. SIN→BKK and BKK→DEL are both fully clean.",
  explanation_bullets: [
    "SIN→BKK first leg is a clean, high-frequency 2.25-hour hop.",
    "BKK→DEL second leg routes northwest over Myanmar — no advisory zone.",
    "Bangkok (BKK) is Southeast Asia's most connected hub — strong recovery options.",
    "Adds approximately 1 hour versus direct due to the Bangkok connection geometry.",
    "Best when direct SIN–DEL capacity is constrained or Thai Airways pricing is competitive."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: del.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · SIN–KUL–DEL",
  path_geojson: line.([[sin.lng, sin.lat], [kul.lng, kul.lat], [88.0, 12.0], [del.lng, del.lat]]),
  distance_km: 4950, typical_duration_minutes: 400, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Both legs clean. SIN–KUL is one of the world's highest-frequency short hops. Best for price-sensitive travel when direct is expensive.",
  ranking_context: "Ranks third: same clean airspace but two-leg geometry is longer and KUL hub score is lower than BKK for this pair.",
  watch_for: "No advisory concerns on either segment. SIN–KUL–DEL is fully clean under current conditions.",
  explanation_bullets: [
    "SIN→KUL is one of the world's busiest short-haul routes — extremely high frequency including LCC options.",
    "KUL→DEL routes northwest over India — clean corridor, no advisory zone.",
    "Malaysia Airlines and AirAsia X serve this with competitive pricing.",
    "Total journey is longer than the Bangkok option due to the two-connection geometry.",
    "Best for budget travel when direct or via-BKK fares are high."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Delhi (3 corridor families: direct, south_asia_bkk/BKK, south_asia_kul/KUL)")

# ─── SINGAPORE → MUMBAI ──────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · daily SIN–BOM; Air India (AI) / IndiGo (6E) · daily SIN–BOM",
  path_geojson: line.([[sin.lng, sin.lat], [88.0, 10.0], [bom.lng, bom.lat]]),
  distance_km: 3950, typical_duration_minutes: 300, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best SIN→BOM option. Clean corridor with no advisory exposure. Singapore Airlines, Air India, and IndiGo provide strong daily frequency and rebooking depth.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, deepest carrier coverage of the three options.",
  watch_for: "No advisory concerns on this corridor. SIN→BOM routes northwest over the Indian Ocean — clean under current conditions.",
  explanation_bullets: [
    "SIN→BOM routes northwest over the Indian Ocean — no advisory zone on this corridor.",
    "Singapore Airlines, Air India, and IndiGo provide multiple daily departures.",
    "At approximately 5 hours, disruption is typically manageable within the same day.",
    "Mumbai (BOM) is India's largest and most connected international hub.",
    "No routing constraint or advisory concern applies under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: bom.id, via_hub_city_id: bkk.id,
  corridor_family: "south_asia_bkk",
  route_name: "Via Bangkok",
  carrier_notes: "Thai Airways (TG) · SIN–BKK–BOM · daily SIN–BKK service",
  path_geojson: line.([[sin.lng, sin.lat], [bkk.lng, bkk.lat], [85.0, 16.0], [bom.lng, bom.lat]]),
  distance_km: 5050, typical_duration_minutes: 405, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Via Bangkok gives Thai Airways connectivity. Both legs clean. Worth considering when direct SIN–BOM is full or a Bangkok stop is desired.",
  ranking_context: "Ranks second: same clean airspace but Bangkok connection adds schedule risk. SIN–BKK frequency is extremely high, reducing that risk.",
  watch_for: "No advisory concerns on either segment. SIN→BKK and BKK→BOM are both fully clean.",
  explanation_bullets: [
    "SIN→BKK first leg is one of Southeast Asia's highest-frequency routes — clean and reliable.",
    "BKK→BOM routes southwest over Bay of Bengal — no advisory zone involvement.",
    "Bangkok hub provides useful Southeast Asia flexibility if BOM-bound flights are disrupted.",
    "Adds approximately 1.5 hours versus direct due to the Bangkok connection.",
    "Best when direct SIN–BOM is sold out or Bangkok is a desired intermediate stop."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: bom.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · SIN–KUL–BOM",
  path_geojson: line.([[sin.lng, sin.lat], [kul.lng, kul.lat], [88.0, 8.0], [bom.lng, bom.lat]]),
  distance_km: 4900, typical_duration_minutes: 395, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Both legs clean. AirAsia X offers competitive SIN–KUL–BOM pricing when direct fares are high.",
  ranking_context: "Ranks third: same clean airspace but KUL is close to SIN, making the routing longer per km than direct. Budget carrier pricing is the main use case.",
  watch_for: "No advisory concerns on either segment. SIN–KUL–BOM is fully clean under current conditions.",
  explanation_bullets: [
    "SIN→KUL is one of the world's busiest short-haul routes — extreme frequency across MH, AirAsia, and others.",
    "KUL→BOM routes northwest over the Indian Ocean — clean corridor, no advisory zone.",
    "AirAsia X serves KUL–BOM with competitive budget fares.",
    "Total journey approximately 6.5 hours — close to Bangkok routing but with KUL as transit hub.",
    "No advisory concern on either leg under current conditions."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Mumbai (3 corridor families: direct, south_asia_bkk/BKK, south_asia_kul/KUL)")

# ─── TOKYO → SINGAPORE ───────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · 1 daily NRT–SIN; ANA · 1 daily NRT–SIN; Japan Airlines (JL) · 1 daily NRT–HND–SIN",
  path_geojson: line.([[nrt.lng, nrt.lat], [125.0, 28.0], [110.0, 15.0], [sin.lng, sin.lat]]),
  distance_km: 5310, typical_duration_minutes: 385, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best NRT→SIN option. Clean southbound corridor over the South China Sea with no advisory zone exposure. Singapore Airlines, ANA, and JAL all serve this pair.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, multiple carriers with strong frequency.",
  watch_for: "NRT–SIN is advisory-clean. South China Sea and East China Sea corridor is unrestricted under current conditions.",
  explanation_bullets: [
    "NRT→SIN routes south over East China Sea and South China Sea — no advisory zone involvement.",
    "Singapore Airlines, ANA, and JAL all serve this pair with daily departures.",
    "Singapore (SIN) is the world's best-connected Southeast Asian hub.",
    "At approximately 6.5 hours, a comfortable corridor with no current advisory constraints.",
    "South China Sea routing is operationally standard and advisory-clean year-round."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: sin.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · NRT–HKG–SIN; strong NRT–HKG frequency",
  path_geojson: line.([[nrt.lng, nrt.lat], [hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
  distance_km: 5820, typical_duration_minutes: 445, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via Hong Kong. Cathay Pacific provides strong NRT–HKG connections with reliable HKG–SIN service. Best when Cathay schedules offer a better connection than direct options.",
  ranking_context: "Ranked second: equivalent advisory cleanliness, slightly longer geometry via HKG. Preferred when Cathay Pacific schedules are more convenient.",
  watch_for: "NRT–HKG–SIN is fully advisory-clean. Monitor HKG connection time — Cathay offers multiple NRT–HKG daily.",
  explanation_bullets: [
    "NRT→HKG routes west over East China Sea — fully advisory-clean.",
    "HKG→SIN continues south over South China Sea — also fully clean.",
    "Cathay Pacific operates reliable NRT–HKG connections; continues HKG–SIN daily.",
    "Total geometry ~5,820 km; slightly longer than direct but equivalent advisory score."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Singapore (2 corridor families: direct, north_asia_hkg/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT ↔ KUALA LUMPUR
# Two families each direction: via Istanbul · via Dubai
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: kul.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily FRA–IST · IST–KUL direct service",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [68.0, 25.0], [kul.lng, kul.lat]]),
  distance_km: 10400, typical_duration_minutes: 765, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current FRA→KUL option. Turkish Airlines via Istanbul avoids the active Gulf advisory zone on the European departure. The FRA–IST leg carries airspace_score 1 for Central Asian FIR proximity; IST–KUL is advisory-clean.",
  ranking_context: "Ranks first: airspace_score 1 vs 2 for Dubai routing. Central Asian FIRs carry EASA advisories but no active conflict zone. Turkish's IST hub provides strong FRA connectivity.",
  watch_for: "FRA–IST departure approaches Central Asian FIRs — EASA-monitored. IST–KUL is advisory-clean via South Asian corridor. Monitor Turkish FIR NOTAMs for flow restrictions.",
  explanation_bullets: [
    "FRA–IST departure routes east — airspace_score 1 for EASA-monitored Central Asian FIRs.",
    "IST–KUL routes southeast via South Asia — fully advisory-clean beyond Turkish FIR.",
    "Turkish Airlines operates reliable FRA–IST with strong IST–KUL connectivity.",
    "Total journey approximately 12.5–13 hours including transit.",
    "Preferred over Gulf routing when advisory minimisation matters."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: kul.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · FRA–DXB–KUL daily; Lufthansa connections into EK at FRA",
  path_geojson: line.([[fra.lng, fra.lat], [35.0, 38.0], [dxb.lng, dxb.lat], [kul.lng, kul.lat]]),
  distance_km: 10300, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "FRA→KUL via Dubai. Emirates operates daily FRA–DXB–KUL. The FRA–DXB departure uses northern routing past Iranian FIR — airspace_score 2. DXB–KUL is advisory-clean. Highest capacity for FRA–Malaysia routing.",
  ranking_context: "Ranked second: airspace_score 2 for Iranian FIR on FRA–DXB northern routing. Single hub at DXB is simpler; advisory exposure is higher than Istanbul option.",
  watch_for: "FRA–DXB northern routing approaches Iranian FIR — EASA advisory applies. Verify status before departure. DXB–KUL is advisory-clean.",
  explanation_bullets: [
    "FRA–DXB northern departure approaches Iranian FIR — airspace_score 2; EASA advisory.",
    "DXB–KUL routes southeast over Arabian Sea and Indian subcontinent — fully advisory-clean.",
    "Emirates FRA–DXB–KUL is the highest-frequency Frankfurt–Malaysia service.",
    "Single hub at DXB; total journey approximately 13–13.5 hours.",
    "Istanbul routing recommended when Iranian FIR advisory is elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Kuala Lumpur (2 corridor families: turkey_hub/IST, gulf_dubai/DXB)")

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: fra.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · KUL–IST–FRA daily; Malaysia Airlines codeshares available",
  path_geojson: line.([[kul.lng, kul.lat], [68.0, 25.0], [ist.lng, ist.lat], [fra.lng, fra.lat]]),
  distance_km: 10400, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best KUL→FRA option. Turkish Airlines via Istanbul avoids Gulf advisory zone on the European arrival leg. KUL–IST is advisory-clean; IST–FRA has airspace_score 1 for Central Asian FIRs.",
  ranking_context: "Ranks first: airspace_score 1 vs 2 for Dubai routing. Turkish hub provides good KUL connectivity with reliable IST–FRA service.",
  watch_for: "IST–FRA arrival leg approaches Central Asian FIRs — EASA-monitored. KUL–IST departure is advisory-clean.",
  explanation_bullets: [
    "KUL–IST departure routes northwest via South Asian airspace — advisory-clean.",
    "IST–FRA arrival crosses Central Asian FIRs — airspace_score 1; EASA-monitored.",
    "Turkish Airlines operates reliable KUL–IST–FRA with strong hub connectivity.",
    "Total journey approximately 12.5–13 hours including transit.",
    "Preferred over Gulf routing for advisory minimisation."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · KUL–DXB–FRA daily; Malaysia Airlines / Emirates codeshares",
  path_geojson: line.([[kul.lng, kul.lat], [dxb.lng, dxb.lat], [35.0, 38.0], [fra.lng, fra.lat]]),
  distance_km: 10300, typical_duration_minutes: 755, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "KUL→FRA via Dubai. Emirates operates daily KUL–DXB–FRA. The DXB–FRA leg uses northern routing past Iranian FIR — airspace_score 2. KUL–DXB is advisory-clean. Highest frequency for KUL–Germany routing.",
  ranking_context: "Ranked second: airspace_score 2 for Iranian FIR on the DXB–FRA outbound. Single hub at DXB is simpler but advisory exposure is higher than Istanbul option.",
  watch_for: "DXB–FRA northern routing approaches Iranian FIR — EASA advisory applies. KUL–DXB is advisory-clean over Indian Ocean.",
  explanation_bullets: [
    "KUL–DXB departure routes northwest over Arabian Sea — fully advisory-clean.",
    "DXB–FRA outbound approaches Iranian FIR via northern routing — airspace_score 2; EASA advisory.",
    "Emirates KUL–DXB–FRA is the highest-frequency Kuala Lumpur–Germany service.",
    "Single hub at DXB; total journey approximately 13–13.5 hours.",
    "Istanbul routing recommended when Iranian FIR advisory is elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Kuala Lumpur → Frankfurt (2 corridor families: turkey_hub/IST, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS ↔ KUALA LUMPUR
# Two families each direction: via Istanbul · via Dubai
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: kul.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily CDG–IST · IST–KUL direct service",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [68.0, 25.0], [kul.lng, kul.lat]]),
  distance_km: 10800, typical_duration_minutes: 790, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current CDG→KUL option. Turkish Airlines via Istanbul avoids the active Gulf advisory zone on the European departure leg. CDG–IST carries airspace_score 1 for Central Asian FIR proximity; IST–KUL is advisory-clean.",
  ranking_context: "Ranks first: airspace_score 1 vs 2 for Dubai routing. EASA-monitored Central Asian FIRs carry advisory notices but no active conflict zone. Turkish's IST hub has strong Paris connectivity.",
  watch_for: "CDG–IST departure approaches Central Asian FIRs — EASA-monitored. IST–KUL is advisory-clean via South Asian corridor.",
  explanation_bullets: [
    "CDG–IST departure routes southeast — airspace_score 1 for EASA-monitored Central Asian FIRs.",
    "IST–KUL routes southeast via South Asia — advisory-clean beyond Turkish FIR.",
    "Turkish Airlines operates reliable CDG–IST with good Paris frequency.",
    "Total journey approximately 13–13.5 hours including transit.",
    "Preferred over Gulf routing when advisory minimisation matters."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: kul.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · CDG–DXB–KUL daily; Air France codeshares via EK at CDG",
  path_geojson: line.([[cdg.lng, cdg.lat], [32.0, 37.0], [dxb.lng, dxb.lat], [kul.lng, kul.lat]]),
  distance_km: 10700, typical_duration_minutes: 785, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CDG→KUL via Dubai. Emirates operates daily CDG–DXB–KUL. The CDG–DXB departure uses northern routing past Iranian FIR — airspace_score 2. DXB–KUL is advisory-clean. Highest capacity for CDG–Malaysia routing.",
  ranking_context: "Ranked second: airspace_score 2 for Iranian FIR on CDG–DXB northern routing. Single hub at DXB is the simplicity advantage; advisory exposure is higher than Istanbul option.",
  watch_for: "CDG–DXB northern routing approaches Iranian FIR — EASA advisory applies. DXB–KUL is advisory-clean over Arabian Sea.",
  explanation_bullets: [
    "CDG–DXB northern departure approaches Iranian FIR — airspace_score 2; EASA advisory.",
    "DXB–KUL routes southeast over Arabian Sea and Indian subcontinent — fully advisory-clean.",
    "Emirates CDG–DXB–KUL is the highest-frequency Paris–Malaysia service.",
    "Single hub at DXB; total journey approximately 13.5–14 hours.",
    "Istanbul routing recommended when Iranian FIR advisory status is elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Kuala Lumpur (2 corridor families: turkey_hub/IST, gulf_dubai/DXB)")

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: cdg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · KUL–IST–CDG daily; Malaysia Airlines codeshares available",
  path_geojson: line.([[kul.lng, kul.lat], [68.0, 25.0], [ist.lng, ist.lat], [cdg.lng, cdg.lat]]),
  distance_km: 10800, typical_duration_minutes: 785, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best KUL→CDG option. Turkish Airlines via Istanbul avoids Gulf advisory zone on the European arrival leg. KUL–IST is advisory-clean; IST–CDG has airspace_score 1 for Central Asian FIRs.",
  ranking_context: "Ranks first: airspace_score 1 vs 2 for Dubai routing. Turkish hub provides good KUL connectivity with reliable IST–CDG service.",
  watch_for: "IST–CDG arrival leg approaches Central Asian FIRs — EASA-monitored. KUL–IST departure is advisory-clean.",
  explanation_bullets: [
    "KUL–IST departure routes northwest via South Asian airspace — advisory-clean.",
    "IST–CDG arrival crosses Central Asian FIRs — airspace_score 1; EASA-monitored.",
    "Turkish Airlines operates reliable KUL–IST–CDG with strong hub connectivity.",
    "Total journey approximately 13–13.5 hours including transit.",
    "Preferred over Gulf routing for advisory minimisation."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · KUL–DXB–CDG daily; Malaysia Airlines / Emirates codeshares",
  path_geojson: line.([[kul.lng, kul.lat], [dxb.lng, dxb.lat], [32.0, 37.0], [cdg.lng, cdg.lat]]),
  distance_km: 10700, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "KUL→CDG via Dubai. Emirates operates daily KUL–DXB–CDG. The DXB–CDG leg uses northern routing past Iranian FIR — airspace_score 2. KUL–DXB is advisory-clean. Highest frequency for KUL–Paris routing.",
  ranking_context: "Ranked second: airspace_score 2 for Iranian FIR on the DXB–CDG outbound. Single hub at DXB is simpler but advisory exposure is higher than Istanbul option.",
  watch_for: "DXB–CDG northern routing approaches Iranian FIR — EASA advisory applies. KUL–DXB is advisory-clean over Indian Ocean.",
  explanation_bullets: [
    "KUL–DXB departure routes northwest over Arabian Sea — fully advisory-clean.",
    "DXB–CDG outbound approaches Iranian FIR via northern routing — airspace_score 2; EASA advisory.",
    "Emirates KUL–DXB–CDG is the highest-frequency Kuala Lumpur–Paris service.",
    "Single hub at DXB; total journey approximately 13.5–14 hours.",
    "Istanbul routing recommended when Iranian FIR advisory is elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Kuala Lumpur → Paris (2 corridor families: turkey_hub/IST, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
