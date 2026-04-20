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

# SINGAPORE → HONG KONG
# Two families: direct · via Bangkok
# Short-haul clean pair. Value is confirming both routes are advisory-clean.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · 4 daily SIN–HKG; Cathay Pacific (CX) · 4 daily SIN–HKG",
  path_geojson: line.([[sin.lng, sin.lat], [hkg.lng, hkg.lat]]),
  distance_km: 2570, typical_duration_minutes: 215, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency short-haul. No advisory zone involvement. SQ and CX combined provide 8+ daily departures — best first choice for SIN→HKG.",
  ranking_context: "First choice. Clean airspace, excellent frequency, both carriers offer strong rebooking depth. No advisory zone contact on this corridor.",
  watch_for: "SIN–HKG is one of the highest-frequency routes in Asia. Only unusual operational event that could affect it is extreme weather or HKG airspace management.",
  explanation_bullets: [
    "South China Sea corridor is advisory-clean — no active EASA or CAA restrictions.",
    "Singapore Airlines and Cathay Pacific together provide 8+ daily departures — among the highest frequencies in Asia.",
    "3.5-hour journey with no advisory exposure is among the cleanest options in the Southeast Asia corridor."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: hkg.id, via_hub_city_id: bkk.id,
  corridor_family: "southeast_asia",
  route_name: "Via Bangkok",
  carrier_notes: "Thai Airways (TG) / THAI + CX · SIN–BKK–HKG",
  path_geojson: line.([[sin.lng, sin.lat], [bkk.lng, bkk.lat], [hkg.lng, hkg.lat]]),
  distance_km: 3170, typical_duration_minutes: 280, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via Bangkok. No advisory zone involvement but adds journey time. Use when direct SIN–HKG options are full.",
  ranking_context: "Ranked below direct due to added connection time and complexity. Airspace is equivalent — both are fully clean. BKK hub is convenient but adds roughly 45–60 minutes.",
  watch_for: "SIN–BKK–HKG is fully clean. BKK has strong THAI and CX connection options.",
  explanation_bullets: [
    "Both SIN–BKK and BKK–HKG segments are clean — no advisory zone involvement.",
    "Bangkok provides additional carrier options (THAI, CX, multiple LCCs) if direct segments are sold out.",
    "Adds approximately 1 hour versus direct due to the Southeast Asia backtrack geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Hong Kong (2 corridor families: direct, southeast_asia/BKK)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → BANGKOK
# Two families: direct · via Singapore
# Short-haul clean pair. Advisory-free but decision value is in confirming that.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Cathay Pacific (CX) · 3 daily HKG–BKK; Thai Airways (TG) · 2 daily HKG–BKK",
  path_geojson: line.([[hkg.lng, hkg.lat], [bkk.lng, bkk.lat]]),
  distance_km: 1710, typical_duration_minutes: 150, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, well-served short-haul. No advisory zone involvement. Cathay Pacific and Thai Airways together provide 5+ daily departures.",
  ranking_context: "First choice. 2.5-hour hop over South China Sea / Indochina — fully clean. Strong carrier frequency and rebooking depth at both hubs.",
  watch_for: "HKG–BKK is advisory-clean. Monitor for weather or political disruptions at BKK — Suvarnabhumi has historically been affected by Thai political events.",
  explanation_bullets: [
    "South China Sea / Indochina corridor is advisory-clean — no EASA or ICAO restrictions active.",
    "Cathay Pacific and Thai Airways provide 5+ daily departures on this route.",
    "No advisory exposure; primary risk is operational disruption at either hub."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: bkk.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) / Cathay + SQ · HKG–SIN–BKK",
  path_geojson: line.([[hkg.lng, hkg.lat], [sin.lng, sin.lat], [bkk.lng, bkk.lat]]),
  distance_km: 3010, typical_duration_minutes: 270, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via Singapore hub. Adds time versus direct but SIN hub provides world-class connections for onward travel. Use when direct is full.",
  ranking_context: "Ranked below direct due to added journey time and one-stop complexity. Airspace is fully clean on both legs.",
  watch_for: "HKG–SIN–BKK is clean. Singapore hub is highly reliable; this routing adds approximately 1.5 hours versus direct.",
  explanation_bullets: [
    "Both HKG–SIN and SIN–BKK segments are clean — no advisory zone involvement.",
    "SIN hub provides world-class connections with strong reliability.",
    "Adds ~1.5 hours versus direct due to the southward detour geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Bangkok (2 corridor families: direct, southeast_asia/SIN)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → SINGAPORE
# Two families: direct · via Bangkok
# High-volume intra-Asia clean pair.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Cathay Pacific (CX) · 4 daily HKG–SIN; Singapore Airlines (SQ) · 4 daily HKG–SIN",
  path_geojson: line.([[hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
  distance_km: 2570, typical_duration_minutes: 215, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency short-haul. SQ and CX combined provide 8+ daily departures — one of the highest-frequency routes in Asia.",
  ranking_context: "First choice. Fully advisory-clean South China Sea corridor with unmatched frequency from two world-class carriers.",
  watch_for: "HKG–SIN is advisory-clean. No active EASA or ICAO restrictions on this corridor.",
  explanation_bullets: [
    "South China Sea corridor — fully advisory-clean, no active restrictions.",
    "Singapore Airlines and Cathay Pacific combined: 8+ daily departures — best frequency in the region.",
    "Both carriers offer strong rebooking depth at both ends."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: sin.id, via_hub_city_id: bkk.id,
  corridor_family: "southeast_asia",
  route_name: "Via Bangkok",
  carrier_notes: "Thai Airways (TG) / multiple LCCs · HKG–BKK–SIN",
  path_geojson: line.([[hkg.lng, hkg.lat], [bkk.lng, bkk.lat], [sin.lng, sin.lat]]),
  distance_km: 3500, typical_duration_minutes: 295, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via Bangkok for when direct options are full. Both legs are advisory-clean. Adds ~1.5 hours versus direct.",
  ranking_context: "Ranked below direct due to time overhead. Airspace is equivalent — fully clean.",
  watch_for: "HKG–BKK–SIN is fully advisory-clean. Adds ~1.5 hours versus direct due to southward detour.",
  explanation_bullets: [
    "HKG–BKK and BKK–SIN are both clean segments — no advisory involvement.",
    "Bangkok hub provides multiple carrier options including low-cost alternatives.",
    "Geometry adds ~1.5 hours due to the southward extension through Southeast Asia."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Singapore (2 corridor families: direct, southeast_asia/BKK)")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → SEOUL
# Two families: direct · via Hong Kong
# South China Sea + East China Sea — advisory-clean. ICN is a strong origin hub.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · 4x daily SIN–ICN; Korean Air (KE) / Asiana (OZ) · multiple daily",
  path_geojson: line.([[sin.lng, sin.lat], [icn.lng, icn.lat]]),
  distance_km: 4710, typical_duration_minutes: 375, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency route over the South China Sea and Philippine Sea. Multiple carrier options with strong rebooking depth at both ICN and SIN.",
  ranking_context: "First choice. Entire corridor is advisory-clean. SQ, KE, and OZ together offer strong frequency and competing fares.",
  watch_for: "SIN–ICN is advisory-clean. No active EASA or ICAO restrictions on this corridor.",
  explanation_bullets: [
    "South China Sea and Philippine Sea corridor — fully advisory-clean, no active restrictions.",
    "Singapore Airlines, Korean Air, and Asiana combined offer 8+ daily departures.",
    "ICN (Incheon) is one of Asia's best-connected hubs — excellent onward connections if needed."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · SIN–HKG–ICN connection",
  path_geojson: line.([[sin.lng, sin.lat], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 5400, typical_duration_minutes: 450, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG for when direct fares are high or schedules don't suit. Both legs are fully advisory-clean.",
  ranking_context: "Ranked below direct due to added connection time (~75 min extra). Airspace is equivalent — fully clean throughout.",
  watch_for: "SIN–HKG–ICN is advisory-clean. Adds ~75 minutes versus direct due to the northern detour through HKG.",
  explanation_bullets: [
    "Both SIN–HKG and HKG–ICN segments are clean — no advisory zone involvement.",
    "Cathay Pacific's HKG hub provides competitive fares on this routing.",
    "Adds approximately 75 minutes versus direct due to the connection geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Seoul (2 corridor families: direct, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → SINGAPORE
# Two families: direct · via Hong Kong
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Korean Air (KE) / Asiana (OZ) · multiple daily ICN–SIN; Singapore Airlines (SQ) · codeshare",
  path_geojson: line.([[icn.lng, icn.lat], [sin.lng, sin.lat]]),
  distance_km: 4710, typical_duration_minutes: 375, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency route. Korean Air and Asiana operate multiple daily departures. No advisory zone involvement on the corridor.",
  ranking_context: "First choice. Advisory-clean corridor with excellent carrier frequency and competitive fares.",
  watch_for: "ICN–SIN is advisory-clean. No active EASA or ICAO restrictions on this corridor.",
  explanation_bullets: [
    "Philippine Sea and South China Sea corridor — fully advisory-clean.",
    "Korean Air and Asiana combined offer strong frequency with good rebooking options.",
    "SIN (Changi) is one of the world's best transit hubs — excellent reliability."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: sin.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · ICN–HKG–SIN connection",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
  distance_km: 5400, typical_duration_minutes: 450, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG. Both legs advisory-clean. Useful when direct options are limited or HKG stopover is desired.",
  ranking_context: "Ranked below direct due to added connection time. Airspace is equivalent — fully clean.",
  watch_for: "ICN–HKG–SIN is advisory-clean. Adds ~75 minutes versus direct.",
  explanation_bullets: [
    "ICN–HKG and HKG–SIN are both clean segments — no advisory involvement.",
    "Cathay Pacific's HKG hub provides strong connectivity options.",
    "Adds approximately 75 minutes versus direct."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Singapore (2 corridor families: direct, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → SINGAPORE
# Two families: direct · via Kuala Lumpur
# High-volume intra-Southeast Asia clean pair. Both cities are major hubs.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Thai Airways (TG) · daily BKK–SIN; Singapore Airlines (SQ) · daily; multiple LCCs",
  path_geojson: line.([[bkk.lng, bkk.lat], [sin.lng, sin.lat]]),
  distance_km: 1450, typical_duration_minutes: 135, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Short, clean, extremely high-frequency route. One of Southeast Asia's busiest corridors with full-service and LCC options.",
  ranking_context: "First choice. Fully advisory-clean, shortest geometry, unmatched frequency including budget carriers.",
  watch_for: "BKK–SIN is advisory-clean. No active EASA or ICAO restrictions. Monitor for Thai ATC slot delays during peak periods.",
  explanation_bullets: [
    "Gulf of Thailand and Malay Peninsula — fully advisory-clean, no active restrictions.",
    "One of Southeast Asia's highest-frequency routes — Thai, SQ, AirAsia, Scoot, and more.",
    "Short block time (~2.25h) with multiple daily options."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: sin.id, via_hub_city_id: kul.id,
  corridor_family: "southeast_asia",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia · BKK–KUL–SIN",
  path_geojson: line.([[bkk.lng, bkk.lat], [kul.lng, kul.lat], [sin.lng, sin.lat]]),
  distance_km: 2100, typical_duration_minutes: 210, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative when direct is full. KUL connection adds ~75 minutes. Useful for budget travel via AirAsia or Malaysia Airlines connecting fares.",
  ranking_context: "Ranked below direct due to added journey time. Airspace is equivalent — fully clean.",
  watch_for: "BKK–KUL–SIN is advisory-clean. Adds ~75 minutes versus direct BKK–SIN.",
  explanation_bullets: [
    "Both BKK–KUL and KUL–SIN are fully advisory-clean segments.",
    "KUL hub adds budget carrier options via AirAsia X and Malaysia Airlines.",
    "Geometry adds ~75 minutes due to the southward loop through KUL."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Singapore (2 corridor families: direct, southeast_asia/KUL)")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → BANGKOK
# Two families: direct · via Kuala Lumpur
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · daily SIN–BKK; Thai Airways (TG) · daily; multiple LCCs",
  path_geojson: line.([[sin.lng, sin.lat], [bkk.lng, bkk.lat]]),
  distance_km: 1450, typical_duration_minutes: 135, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Short, clean, extremely high-frequency route. One of Southeast Asia's busiest corridors. Full-service and LCC options available.",
  ranking_context: "First choice. Fully advisory-clean, shortest geometry, unmatched frequency.",
  watch_for: "SIN–BKK is advisory-clean. No active EASA or ICAO restrictions.",
  explanation_bullets: [
    "Malay Peninsula and Gulf of Thailand — fully advisory-clean, no active restrictions.",
    "Singapore Airlines, Thai Airways, AirAsia, Scoot: multiple daily departures.",
    "Short block time (~2.25h) — one of Asia's most reliable short-haul links."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: bkk.id, via_hub_city_id: kul.id,
  corridor_family: "southeast_asia",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia · SIN–KUL–BKK",
  path_geojson: line.([[sin.lng, sin.lat], [kul.lng, kul.lat], [bkk.lng, bkk.lat]]),
  distance_km: 2100, typical_duration_minutes: 210, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via KUL. Both legs fully advisory-clean. Budget-friendly via AirAsia connecting fares.",
  ranking_context: "Ranked below direct due to added connection time. Airspace is equivalent — fully clean.",
  watch_for: "SIN–KUL–BKK is advisory-clean. Adds ~75 minutes versus direct.",
  explanation_bullets: [
    "Both SIN–KUL and KUL–BKK are fully advisory-clean segments.",
    "AirAsia and Malaysia Airlines offer competitive connecting fares through KUL.",
    "Geometry adds ~75 minutes due to the northward loop through KUL."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Bangkok (2 corridor families: direct, southeast_asia/KUL)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → PARIS
# Three families: Central Asia direct · via Istanbul · via Dubai
# Iran-sensitive: Central Asia direct overflies Central Asian airspace.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: cdg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Central Asia Direct",
  carrier_notes: "Cathay Pacific (CX) · 3x daily HKG–CDG via Central Asian FIRs",
  path_geojson: line.([[hkg.lng, hkg.lat], [73.0, 43.0], [cdg.lng, cdg.lat]]),
  distance_km: 9330, typical_duration_minutes: 675, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cathay's standard routing. Transits Central Asian FIRs (Kazakhstan/Uzbekistan) which remain open but require monitoring. Fastest option when advisories are stable.",
  ranking_context: "Primary routing for HKG–CDG on Cathay Pacific. Central Asian airspace is open but not clean — EASA advises vigilance.",
  watch_for: "Central Asian FIRs (KAZ, UZB) require monitoring. Check EASA and Cathay Pacific operational advisories before departure.",
  explanation_bullets: [
    "Central Asian corridor (Kazakhstan/Uzbekistan FIRs) — open but EASA-monitored.",
    "Iran airspace avoided on this routing — stays north of IRI FIR.",
    "Cathay Pacific provides 3 daily departures with strong rebooking options.",
    "Fastest geometry: ~11h direct versus 13h+ for Gulf alternatives."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: cdg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · HKG–IST–CDG connection",
  path_geojson: line.([[hkg.lng, hkg.lat], [ist.lng, ist.lat], [cdg.lng, cdg.lat]]),
  distance_km: 10800, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Good alternative when Central Asian advisories are elevated. HKG–IST–CDG avoids the most sensitive Central Asian segments. Turkish Airlines provides strong frequency.",
  ranking_context: "Ranked below Central Asia direct for time (adds ~2h) but preferred when Central Asian advisory risk is elevated.",
  watch_for: "HKG–IST segment may transit southern Central Asian FIRs depending on filed routing. Confirm with Turkish Airlines.",
  explanation_bullets: [
    "HKG–IST routing arcs south of Kazakhstan — avoids most Central Asian advisory segments.",
    "IST–CDG is fully advisory-clean western European corridor.",
    "Turkish Airlines offers strong HKG–IST frequency and good rebooking depth at IST.",
    "Adds approximately 2 hours versus the Central Asia direct routing."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_hub",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · HKG–DXB–CDG; Cathay + Emirates interline",
  path_geojson: line.([[hkg.lng, hkg.lat], [dxb.lng, dxb.lat], [cdg.lng, cdg.lat]]),
  distance_km: 11200, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Gulf routing avoids Central Asia entirely. HKG–DXB transits South China Sea and Indian subcontinent — advisory-clean. DXB–CDG is clean. Longer but fully advisory-clear.",
  ranking_context: "Ranked third for time (~13.5h total) but preferred if Central Asian advisories are at critical level. Gulf routing is well-established.",
  watch_for: "HKG–DXB routing may approach Iranian FIR boundary — verify filed routing with Emirates. DXB–CDG is fully clean.",
  explanation_bullets: [
    "HKG–DXB transits South China Sea and Bay of Bengal — no active EASA advisories.",
    "DXB–CDG western route is fully advisory-clean.",
    "Emirates offers 3+ daily HKG–DXB departures — strong rebooking depth.",
    "Longest geometry (~13.5h) but fully avoids Central Asian advisory segments."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Paris (3 corridor families: central_asia, turkey_hub/IST, gulf_hub/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → HONG KONG
# One family: direct
# East China Sea / South China Sea — advisory-clean short-haul.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Korean Air (KE) / Asiana (OZ) · 5+ daily ICN–HKG; Cathay Pacific (CX) · codeshare",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat]]),
  distance_km: 2090, typical_duration_minutes: 185, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Short, clean, very high-frequency route over the Yellow Sea and East China Sea. Korean carriers and Cathay combined provide 8+ daily departures.",
  ranking_context: "First and only major family. Fully advisory-clean, excellent frequency, strong hub at both ends.",
  watch_for: "ICN–HKG is advisory-clean. No active EASA or ICAO restrictions. Monitor typhoon disruptions July–October.",
  explanation_bullets: [
    "Yellow Sea and East China Sea corridor — fully advisory-clean, no active restrictions.",
    "Korean Air and Asiana offer 5+ daily departures; Cathay Pacific provides additional frequency.",
    "Both ICN and HKG are world-class hubs with strong rebooking support.",
    "Short block time (~3h) with multiple schedule options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Hong Kong (1 corridor family: direct)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → SEOUL
# One family: direct
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Cathay Pacific (CX) · 5+ daily HKG–ICN; Korean Air (KE) / Asiana (OZ) · codeshare",
  path_geojson: line.([[hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 2090, typical_duration_minutes: 185, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Short, clean, very high-frequency route. Cathay Pacific and Korean carriers together provide 8+ daily departures. No advisory zone involvement.",
  ranking_context: "First and only major family. Fully advisory-clean, excellent frequency, strong hub at both ends.",
  watch_for: "HKG–ICN is advisory-clean. No active EASA or ICAO restrictions. Monitor typhoon disruptions July–October.",
  explanation_bullets: [
    "South China Sea and East China Sea corridor — fully advisory-clean.",
    "Cathay Pacific operates 5+ daily HKG–ICN departures with strong reliability.",
    "Both HKG and ICN are major Asian hubs with excellent rebooking depth.",
    "Short block time (~3h) with flexible scheduling."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Seoul (1 corridor family: direct)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → SEOUL
# Two families: direct · via Hong Kong
# Indochina Peninsula + South China Sea — advisory-clean.
# High-volume leisure and business corridor between Thailand and South Korea.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Thai Airways (TG) · daily BKK–ICN; Korean Air (KE) · daily; Asiana (OZ) · daily; Jin Air / Air Seoul LCCs",
  path_geojson: line.([[bkk.lng, bkk.lat], [icn.lng, icn.lat]]),
  distance_km: 3700, typical_duration_minutes: 300, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency route. Thai Airways, Korean Air, Asiana, and multiple LCCs provide strong daily capacity on this popular leisure corridor.",
  ranking_context: "First choice. Fully advisory-clean corridor over the South China Sea with multiple carrier options including budget alternatives.",
  watch_for: "BKK–ICN is advisory-clean. No active EASA or ICAO restrictions. High passenger volume — book early during Thai and Korean school holiday periods.",
  explanation_bullets: [
    "Indochina Peninsula and South China Sea corridor — fully advisory-clean, no active restrictions.",
    "Thai Airways, Korean Air, and Asiana operate daily services; LCCs add further frequency.",
    "One of Southeast Asia's highest-demand leisure routes — availability can tighten during holidays."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · BKK–HKG–ICN connection",
  path_geojson: line.([[bkk.lng, bkk.lat], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 4400, typical_duration_minutes: 375, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG when direct is unavailable or overpriced. Both legs are fully advisory-clean. Cathay Pacific's HKG hub is reliable.",
  ranking_context: "Ranked below direct due to added connection time. Airspace is equivalent — fully clean throughout.",
  watch_for: "BKK–HKG–ICN is advisory-clean. Adds approximately 75 minutes versus direct due to the HKG detour.",
  explanation_bullets: [
    "Both BKK–HKG and HKG–ICN segments are fully advisory-clean.",
    "Cathay Pacific's HKG hub provides competitive connecting fares.",
    "Adds approximately 75 minutes versus direct BKK–ICN."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Seoul (2 corridor families: direct, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → BANGKOK
# Two families: direct · via Hong Kong
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Korean Air (KE) · daily ICN–BKK; Asiana (OZ) · daily; Thai Airways (TG) · daily; Jin Air LCC",
  path_geojson: line.([[icn.lng, icn.lat], [bkk.lng, bkk.lat]]),
  distance_km: 3700, typical_duration_minutes: 300, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency route. Korean Air, Asiana, Thai Airways, and Jin Air provide strong capacity on one of Northeast-Southeast Asia's most popular corridors.",
  ranking_context: "First choice. Fully advisory-clean corridor with excellent carrier depth and both full-service and budget options.",
  watch_for: "ICN–BKK is advisory-clean. No active EASA or ICAO restrictions. Book early for Thai Songkran (April) and Korean summer holiday peak periods.",
  explanation_bullets: [
    "South China Sea and Indochina Peninsula — fully advisory-clean, no active restrictions.",
    "Korean Air, Asiana, Thai Airways, and Jin Air together provide 5+ daily departures.",
    "High-demand leisure route — fares and availability tighten significantly during Thai and Korean peak holidays."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: bkk.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · ICN–HKG–BKK connection",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat], [bkk.lng, bkk.lat]]),
  distance_km: 4400, typical_duration_minutes: 375, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG. Both legs fully advisory-clean. Useful when direct options are limited or Cathay Pacific fares are competitive.",
  ranking_context: "Ranked below direct due to added connection time. Airspace is equivalent — fully clean.",
  watch_for: "ICN–HKG–BKK is advisory-clean. Adds approximately 75 minutes versus direct.",
  explanation_bullets: [
    "Both ICN–HKG and HKG–BKK segments are fully advisory-clean.",
    "Cathay Pacific's HKG hub is well-positioned between Seoul and Bangkok.",
    "Adds approximately 75 minutes versus direct."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Bangkok (2 corridor families: direct, north_asia/HKG)")

IO.puts("")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → TOKYO
# Three families: direct · via Singapore · via Hong Kong
# South China Sea + Philippine Sea + East China Sea — fully advisory-clean.
# One of the highest-volume SEA→NEA routes. No Iran-corridor involvement.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Thai Airways (TG) · daily BKK–NRT; Japan Airlines (JL) · daily; ANA · daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [nrt.lng, nrt.lat]]),
  distance_km: 4610, typical_duration_minutes: 360, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency route over the South China Sea and Philippine Sea. Thai Airways, JAL, and ANA provide strong daily capacity. No advisory zone involvement.",
  ranking_context: "First choice. Entirely advisory-clean corridor with multiple full-service carrier options and competitive fares.",
  watch_for: "BKK–NRT is advisory-clean. No active EASA or ICAO restrictions. Book early during Japanese Golden Week (late April–early May) and Thai school holidays.",
  explanation_bullets: [
    "Gulf of Thailand, South China Sea, and Philippine Sea — fully advisory-clean, no active restrictions.",
    "Thai Airways, JAL, and ANA combined provide 5+ daily departures with strong schedules.",
    "NRT (Narita) and HND (Haneda) both served — check which terminal suits your onward connections."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: nrt.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · BKK–SIN–NRT connection",
  path_geojson: line.([[bkk.lng, bkk.lat], [sin.lng, sin.lat], [nrt.lng, nrt.lat]]),
  distance_km: 6260, typical_duration_minutes: 510, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via SIN for when direct fares are high or schedules don't align. Singapore Airlines' SIN–NRT segment is one of the most reliable in the region.",
  ranking_context: "Ranked below direct due to added connection time (~2.5h extra). Airspace is equivalent — fully clean throughout.",
  watch_for: "BKK–SIN–NRT is advisory-clean. Adds approximately 2.5 hours versus direct due to the southward SIN connection.",
  explanation_bullets: [
    "Both BKK–SIN and SIN–NRT segments are fully advisory-clean.",
    "Singapore Airlines offers multiple daily SIN–NRT departures with excellent reliability.",
    "Adds ~2.5 hours versus direct due to the southward connection geometry through SIN."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · BKK–HKG–NRT connection",
  path_geojson: line.([[bkk.lng, bkk.lat], [hkg.lng, hkg.lat], [nrt.lng, nrt.lat]]),
  distance_km: 5210, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG. Both legs fully advisory-clean. Cathay Pacific's HKG hub is well-placed on the BKK–NRT geometry and adds less time than the SIN routing.",
  ranking_context: "Ranked below direct but preferable to SIN routing on time. Both legs clean — adds ~75 minutes versus direct.",
  watch_for: "BKK–HKG–NRT is advisory-clean. Adds approximately 75 minutes versus direct due to the HKG connection.",
  explanation_bullets: [
    "BKK–HKG and HKG–NRT are both fully advisory-clean segments.",
    "Cathay Pacific's HKG hub sits closer to the direct BKK–NRT geometry than SIN — less detour.",
    "Adds ~75 minutes versus direct."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Tokyo (3 corridor families: direct, southeast_asia/SIN, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# TOKYO → BANGKOK
# Three families: direct · via Singapore · via Hong Kong
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Japan Airlines (JL) · daily NRT–BKK; ANA · daily; Thai Airways (TG) · daily",
  path_geojson: line.([[nrt.lng, nrt.lat], [bkk.lng, bkk.lat]]),
  distance_km: 4610, typical_duration_minutes: 360, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Clean, high-frequency route. JAL, ANA, and Thai Airways provide multiple daily departures. No advisory zone involvement on the corridor.",
  ranking_context: "First choice. Fully advisory-clean, excellent carrier frequency, competitive fares.",
  watch_for: "NRT–BKK is advisory-clean. No active EASA or ICAO restrictions.",
  explanation_bullets: [
    "Philippine Sea and South China Sea corridor — fully advisory-clean.",
    "JAL, ANA, and Thai Airways together provide 5+ daily departures.",
    "Both NRT and HND served — check departure airport for your ticket."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: bkk.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · NRT–SIN–BKK connection",
  path_geojson: line.([[nrt.lng, nrt.lat], [sin.lng, sin.lat], [bkk.lng, bkk.lat]]),
  distance_km: 6260, typical_duration_minutes: 510, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via SIN. Both legs advisory-clean. Singapore Airlines offers strong NRT–SIN–BKK frequency. Adds time but provides SIN hub connectivity.",
  ranking_context: "Ranked below direct due to added connection time. Airspace is equivalent — fully clean.",
  watch_for: "NRT–SIN–BKK is advisory-clean. Adds approximately 2.5 hours versus direct.",
  explanation_bullets: [
    "Both NRT–SIN and SIN–BKK segments are fully advisory-clean.",
    "Singapore Airlines provides strong NRT–SIN frequency with reliable connections.",
    "Adds ~2.5 hours versus direct due to the southward SIN connection geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: bkk.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · NRT–HKG–BKK connection",
  path_geojson: line.([[nrt.lng, nrt.lat], [hkg.lng, hkg.lat], [bkk.lng, bkk.lat]]),
  distance_km: 5210, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG. Less detour than SIN routing. Both legs fully advisory-clean. Cathay Pacific offers strong NRT–HKG–BKK connections.",
  ranking_context: "Ranked below direct but preferable to SIN on time. Adds ~75 minutes versus direct.",
  watch_for: "NRT–HKG–BKK is advisory-clean. Adds approximately 75 minutes versus direct.",
  explanation_bullets: [
    "NRT–HKG and HKG–BKK are both fully advisory-clean segments.",
    "HKG sits closer to the direct NRT–BKK geometry than SIN — less detour.",
    "Cathay Pacific offers competitive fares on this connection."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Bangkok (3 corridor families: direct, southeast_asia/SIN, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → SEOUL
# Three families: central_asia direct · via Singapore · via Hong Kong
# Iran-sensitive: central_asia direct overflies northern Central Asian FIRs.
# DEL–ICN is a growing South Asia→Northeast Asia corridor.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Central Asia Direct",
  carrier_notes: "Korean Air (KE) · 4x weekly DEL–ICN; Air India (AI) · daily; Asiana (OZ) · codeshare",
  path_geojson: line.([[del.lng, del.lat], [73.0, 43.0], [icn.lng, icn.lat]]),
  distance_km: 5820, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Standard routing for DEL–ICN. Transits Central Asian FIRs (Kazakhstan/Uzbekistan) which are open but EASA-monitored. Fastest option when advisories are stable.",
  ranking_context: "Primary routing. Central Asian airspace is open but requires monitoring — check current EASA notices before departure.",
  watch_for: "Central Asian FIRs (KAZ, UZB) on the DEL–ICN corridor require monitoring. Verify with Korean Air or Air India for current filed routing.",
  explanation_bullets: [
    "DEL–ICN direct transits Central Asian FIRs — open but subject to EASA monitoring notices.",
    "Korean Air operates 4x weekly DEL–ICN; Air India serves the route daily.",
    "Avoids Iran FIR — routing stays north of IRI airspace.",
    "Fastest geometry (~7.25h) versus southern alternatives."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: icn.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · DEL–SIN–ICN; IndiGo (6E) + SQ interline",
  path_geojson: line.([[del.lng, del.lat], [sin.lng, sin.lat], [icn.lng, icn.lat]]),
  distance_km: 7850, typical_duration_minutes: 630, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Fully advisory-clean southern routing via SIN. Both legs avoid Central Asian FIRs entirely. Preferred when Central Asian advisories are elevated. Adds significant time.",
  ranking_context: "Ranked below direct for time (~10.5h total) but fully avoids all Central Asian advisory segments. Strong alternative when DEL–ICN direct advisories are elevated.",
  watch_for: "DEL–SIN–ICN is fully advisory-clean. Adds approximately 3 hours versus Central Asia direct due to the southern routing geometry.",
  explanation_bullets: [
    "Both DEL–SIN and SIN–ICN segments are fully advisory-clean — no Central Asian FIR involvement.",
    "Singapore Airlines provides strong DEL–SIN and SIN–ICN frequency.",
    "Adds ~3 hours versus direct but entirely avoids Central Asian advisory segments.",
    "Preferred routing when KAZ/UZB advisory notices are at elevated or critical level."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · DEL–HKG–ICN connection",
  path_geojson: line.([[del.lng, del.lat], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 6900, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG. Avoids Central Asian FIRs by routing southeast via India and South China Sea. Adds ~1.75h versus direct but fully advisory-clean.",
  ranking_context: "Ranked between Central Asia direct and SIN routing on time. Fully advisory-clean — preferred when Central Asian advisories are active.",
  watch_for: "DEL–HKG–ICN is advisory-clean. Adds approximately 1.75 hours versus Central Asia direct.",
  explanation_bullets: [
    "DEL–HKG routes southeast over the Indian subcontinent — avoids Central Asian FIRs.",
    "HKG–ICN segment is fully advisory-clean over South China Sea.",
    "Cathay Pacific provides strong DEL–HKG connections with reliable onward service to ICN.",
    "Adds ~1.75 hours versus Central Asia direct but fully clears advisory zone involvement."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Seoul (3 corridor families: central_asia, southeast_asia/SIN, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → DELHI
# Three families: central_asia direct · via Singapore · via Hong Kong
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Central Asia Direct",
  carrier_notes: "Korean Air (KE) · 4x weekly ICN–DEL; Air India (AI) · daily direct",
  path_geojson: line.([[icn.lng, icn.lat], [73.0, 43.0], [del.lng, del.lat]]),
  distance_km: 5820, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Standard routing for ICN–DEL. Transits Central Asian FIRs (Kazakhstan/Uzbekistan). Open but EASA-monitored. Fastest option when Central Asian advisories are stable.",
  ranking_context: "Primary routing. Verify current EASA notices on Central Asian FIRs before departure.",
  watch_for: "Central Asian FIRs (KAZ, UZB) on ICN–DEL require monitoring. Korean Air and Air India both file this routing — verify before departure.",
  explanation_bullets: [
    "ICN–DEL direct transits Central Asian FIRs — open but EASA-monitored.",
    "Korean Air and Air India both serve ICN–DEL direct.",
    "Routing stays north of IRI (Iran) airspace.",
    "Fastest geometry (~7.25h) versus southern alternatives."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: del.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · ICN–SIN–DEL connection",
  path_geojson: line.([[icn.lng, icn.lat], [sin.lng, sin.lat], [del.lng, del.lat]]),
  distance_km: 7850, typical_duration_minutes: 630, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Fully advisory-clean southern routing via SIN. Both legs avoid Central Asian FIRs entirely. Preferred when Central Asian advisories are elevated.",
  ranking_context: "Ranked below direct for time (~10.5h total) but fully avoids Central Asian advisory segments. Preferred when KAZ/UZB advisory notices are elevated.",
  watch_for: "ICN–SIN–DEL is fully advisory-clean. Adds approximately 3 hours versus Central Asia direct.",
  explanation_bullets: [
    "Both ICN–SIN and SIN–DEL segments are fully advisory-clean.",
    "Singapore Airlines provides strong frequency on both legs.",
    "Entirely avoids Central Asian FIRs — preferred when advisories are elevated.",
    "Adds ~3 hours versus direct due to the southward routing through SIN."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: del.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · ICN–HKG–DEL connection",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat], [del.lng, del.lat]]),
  distance_km: 6900, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean alternative via HKG. Avoids Central Asian FIRs by routing southwest via South China Sea and Indian subcontinent. Adds ~1.75h versus direct.",
  ranking_context: "Ranked between Central Asia direct and SIN routing on time. Fully advisory-clean.",
  watch_for: "ICN–HKG–DEL is advisory-clean. Adds approximately 1.75 hours versus Central Asia direct.",
  explanation_bullets: [
    "ICN–HKG segment is clean over the South China Sea.",
    "HKG–DEL routes southwest over the Indian subcontinent — avoids Central Asian FIRs.",
    "Cathay Pacific offers reliable ICN–HKG–DEL connections.",
    "Adds ~1.75 hours versus direct but fully advisory-clean."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Delhi (3 corridor families: central_asia, southeast_asia/SIN, north_asia/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
