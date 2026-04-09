alias Pathfinder.Repo
alias Pathfinder.Routes.{City, Route, RouteScore}
alias Pathfinder.Disruption.DisruptionZone
alias Pathfinder.Scoring
alias Pathfinder.CitySlug

# ─── CITIES ───────────────────────────────────────────────────────────────────

cities_data = [
  %{name: "London",       country: "United Kingdom", iata_codes: ["LHR","LGW"], lat: 51.477, lng: -0.461},
  %{name: "Frankfurt",    country: "Germany",         iata_codes: ["FRA"],       lat: 50.033, lng: 8.570},
  %{name: "Amsterdam",    country: "Netherlands",     iata_codes: ["AMS"],       lat: 52.308, lng: 4.764},
  %{name: "Paris",        country: "France",          iata_codes: ["CDG","ORY"], lat: 49.010, lng: 2.549},
  %{name: "Istanbul",     country: "Turkey",          iata_codes: ["IST"],       lat: 40.976, lng: 28.816},
  %{name: "Dubai",        country: "UAE",             iata_codes: ["DXB"],       lat: 25.253, lng: 55.364},
  %{name: "Doha",         country: "Qatar",           iata_codes: ["DOH"],       lat: 25.273, lng: 51.608},
  %{name: "Abu Dhabi",    country: "UAE",             iata_codes: ["AUH"],       lat: 24.433, lng: 54.651},
  %{name: "Singapore",    country: "Singapore",       iata_codes: ["SIN"],       lat: 1.359,  lng: 103.989},
  %{name: "Bangkok",      country: "Thailand",        iata_codes: ["BKK"],       lat: 13.681, lng: 100.747},
  %{name: "Hong Kong",    country: "China SAR",       iata_codes: ["HKG"],       lat: 22.309, lng: 113.915},
  %{name: "Tokyo",        country: "Japan",           iata_codes: ["NRT","HND"], lat: 35.765, lng: 140.386},
  %{name: "Kuala Lumpur", country: "Malaysia",        iata_codes: ["KUL"],       lat: 2.743,  lng: 101.710},
  %{name: "Delhi",        country: "India",           iata_codes: ["DEL"],       lat: 28.556, lng: 77.103},
  %{name: "Mumbai",       country: "India",           iata_codes: ["BOM"],       lat: 19.089, lng: 72.868},
  %{name: "Seoul",        country: "South Korea",     iata_codes: ["ICN"],       lat: 37.456, lng: 126.451},
  %{name: "Colombo",      country: "Sri Lanka",       iata_codes: ["CMB"],       lat: 7.180,  lng: 79.884},
  %{name: "Jakarta",      country: "Indonesia",       iata_codes: ["CGK"],       lat: -6.127, lng: 106.656},
  %{name: "Sydney",       country: "Australia",       iata_codes: ["SYD"],       lat: -33.946, lng: 151.177},
  %{name: "Madrid",       country: "Spain",           iata_codes: ["MAD"],       lat: 40.472,  lng: -3.561},
  %{name: "Munich",       country: "Germany",          iata_codes: ["MUC"],       lat: 48.354,  lng: 11.786},
  %{name: "Rome",         country: "Italy",             iata_codes: ["FCO"],       lat: 41.804,  lng: 12.239},
  %{name: "Zurich",       country: "Switzerland",       iata_codes: ["ZRH"],       lat: 47.464,  lng: 8.549},
  %{name: "Beijing",      country: "China",             iata_codes: ["PEK","PKX"], lat: 40.070,  lng: 116.590},
  %{name: "New York",    country: "United States",     iata_codes: ["JFK","EWR"], lat: 40.641,  lng: -73.778},
  %{name: "Los Angeles", country: "United States",     iata_codes: ["LAX"],       lat: 33.943,  lng: -118.408},
  %{name: "Toronto",     country: "Canada",            iata_codes: ["YYZ"],       lat: 43.677,  lng: -79.631},
  %{name: "Vancouver",   country: "Canada",            iata_codes: ["YVR"],       lat: 49.195,  lng: -123.184},
  %{name: "Shanghai",    country: "China",             iata_codes: ["PVG","SHA"], lat: 31.143,  lng: 121.805},
]

cities =
  Enum.reduce(cities_data, %{}, fn attrs, acc ->
    attrs = Map.put(attrs, :slug, CitySlug.from_name(attrs.name))
    city =
      case Repo.get_by(City, name: attrs.name) do
        nil      -> Repo.insert!(City.changeset(%City{}, attrs))
        existing -> Repo.update!(City.changeset(existing, attrs))
      end
    Map.put(acc, attrs.name, city)
  end)

IO.puts("✓ #{map_size(cities)} cities")

# ─── DISRUPTION ZONES ─────────────────────────────────────────────────────────
# Zone definitions live in lib/pathfinder/disruption/zone_definitions.ex.
# To update advisory status, severity, or copy, edit that file and re-run seeds.

zones =
  Enum.reduce(Pathfinder.Disruption.ZoneDefinitions.all(), %{}, fn attrs, acc ->
    zone =
      case Repo.get_by(DisruptionZone, slug: attrs.slug) do
        nil      -> Repo.insert!(DisruptionZone.changeset(%DisruptionZone{}, attrs))
        existing -> Repo.update!(DisruptionZone.changeset(existing, attrs))
      end
    Map.put(acc, attrs.slug, zone)
  end)

IO.puts("✓ #{map_size(zones)} disruption zones")

# ─── ROUTE CLEANUP ───────────────────────────────────────────────────────────
# Deactivate all routes before re-seeding so stale routes from previous runs
# (e.g. renamed routes) don't appear in results. Each upsert below re-enables
# the routes it owns via is_active: true.

import Ecto.Query
{deactivated, _} = Repo.update_all(Route, set: [is_active: false])
IO.puts("  ↺ deactivated #{deactivated} stale routes")

# ─── HELPERS ──────────────────────────────────────────────────────────────────

now      = DateTime.utc_now() |> DateTime.truncate(:second)
# reviewed represents when a human last assessed the route copy.
# Set to 2 days ago so freshly-seeded routes start as :current (< 7-day threshold).
# The FreshnessUpdateJob will age this naturally in production.
reviewed = DateTime.add(now, -2 * 86_400, :second)

# Compute honest initial freshness based on data age
initial_freshness =
  cond do
    DateTime.diff(now, reviewed, :day) > 30 -> "stale"
    DateTime.diff(now, reviewed, :day) > 7  -> "aging"
    true -> "current"
  end

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
  # Derive all computed fields (structural, pressure, composite, label, cap_reason)
  # from the five factor inputs. Callers only need to pass factor scores and text fields.
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
c = cities

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

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → BANGKOK
# Three families: Turkey hub · Gulf · North Asia (HKG)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily departures LHR–IST–BKK",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9430, typical_duration_minutes: 690, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best current option for LHR→BKK. Avoids the Middle East advisory zone on both legs. Turkish Airlines' IST–BKK service is direct and among the most frequent on this corridor.",
  ranking_context: "Ranks above Gulf options because it avoids the active Middle East advisory zone entirely on both legs. Ranks above Hong Kong because it does not depend on the Central Asian corridor for the second leg.",
  watch_for: "Turkish domestic political tensions periodically affect IST operations. Check TK status within 48 hours of departure.",
  explanation_bullets: [
    "Route routes south of Ukraine and clear of Iranian airspace — no transit through the active Middle East advisory zone on either leg.",
    "Turkish Airlines holds 2 daily LHR–IST departures and 4+ daily IST–BKK services, giving strong rebooking depth if disruption occurs.",
    "Istanbul (IST) hub sits ~900km from the Ukrainian conflict zone — within regional monitoring range but not operationally affected as of last review.",
    "Journey time has settled at 11.5 hours. This is 45 min longer than pre-2022 but variance is now low — the routing pattern has stabilised.",
    "Structurally: single-stop, no excessive detour. This is the most direct viable path for this pair under current airspace conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily LHR–DXB, 4 daily DXB–BKK",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 10100, typical_duration_minutes: 750, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency option with strong rebooking depth, but the Europe-to-Gulf leg transits the active Middle East advisory zone.",
  ranking_context: "Ranked below Istanbul because the London–Dubai leg crosses the active advisory zone. High frequency but real airspace exposure — don't let the overall score obscure it.",
  watch_for: "Monitor regional escalation around the Levant and Gulf. A step-change in conflict intensity could affect routing options or hub operations at DXB with limited warning.",
  explanation_bullets: [
    "The LHR–DXB leg transits the Middle East advisory zone — this is the route's main risk factor and should be understood, not dismissed.",
    "Emirates operates 4 daily LHR–DXB services, which provides the best rebooking flexibility of any option on this pair if disruption forces a change.",
    "Dubai (DXB) airport has demonstrated strong resilience throughout the current conflict period, operating without closure or significant restriction.",
    "DXB–BKK is a clean, uncongested segment with no active advisory concerns.",
    "Total journey is ~45–60 minutes longer than the Istanbul option due to more southerly routing geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: bkk.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · 2 daily LHR–HKG–BKK",
  path_geojson: line.([[lhr.lng, lhr.lat], [52.0, 46.0], [85.0, 43.0], [hkg.lng, hkg.lat], [bkk.lng, bkk.lat]]),
  distance_km: 11800, typical_duration_minutes: 820, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Avoids Gulf and Middle East completely. Best choice if you want to keep both legs away from the active advisory zone, but total journey is longer.",
  ranking_context: "Same clean airspace as Istanbul — neither leg touches the advisory zone. Ranked lower because the LHR–HKG first leg runs through the most congested section of the Central Asian corridor, which adds schedule risk.",
  watch_for: "LHR–HKG uses the Central Asian corridor. If Eurocontrol flow restrictions are in effect on departure day, the first leg is vulnerable to delays.",
  explanation_bullets: [
    "Neither leg touches the Middle East advisory zone: LHR→HKG goes east via Central Asia, HKG→BKK goes south via South China Sea — a completely Gulf-free routing.",
    "Hong Kong (HKG) is one of the world's most resilient hubs. Cathay Pacific has maintained full LHR service throughout the post-2022 disruption period.",
    "The LHR–HKG leg relies on the Central Asian corridor — the same structural bottleneck as Istanbul routing, but occurring on the first leg rather than the second.",
    "Total journey is approximately 80 minutes longer than the Istanbul option due to the more easterly routing geometry.",
    "This corridor makes most sense if Gulf escalation drives you to avoid Middle East airspace on both segments, not just one."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Bangkok (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → SINGAPORE
# Three families: Turkey hub · Gulf · North Asia (HKG)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily LHR–IST–SIN",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 11190, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for LHR→SIN. Avoids the Middle East advisory zone on both legs. Turkish Airlines and Singapore Airlines both serve this pairing via IST, giving strong combined frequency.",
  ranking_context: "Ranks above both Gulf options because the LHR–IST–SIN routing avoids the advisory zone on both legs. Istanbul is a natural waypoint east from London — no geometric detour, unlike the HKG backtrack.",
  watch_for: "IST–SIN second leg routes over Iran/Pakistan. If Iranian FIR restrictions tighten, this leg could be rerouted, adding up to 40 minutes.",
  explanation_bullets: [
    "LHR–IST uses standard European routing — no restricted airspace. IST–SIN routes east via Iran/Central Asia, which carries a level-1 advisory but no active routing restriction.",
    "Turkish Airlines and Singapore Airlines share strong codeshare depth on this pairing, providing 4+ daily frequency options from IST to SIN.",
    "Journey time is now consistently 13.5 hours — stable since late 2023 after airlines settled into post-Russia routes.",
    "Istanbul hub sits outside the Middle East advisory zone proper, though its geographic position means regional escalations are worth monitoring.",
    "If Iranian FIR applies sudden NOTAM restrictions, the IST–SIN leg may need mid-route adjustment — a low-probability but non-zero risk."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Singapore Airlines (SQ)",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
  distance_km: 11870, typical_duration_minutes: 855, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Reliable option with high frequency, but the LHR–DXB leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranked behind Istanbul because the London–Dubai leg crosses the active advisory zone. Both have high frequency; the airspace exposure is the differentiator.",
  watch_for: "The DXB hub has operated without closure throughout current regional tensions, but rapid escalation in the Levant or Iranian situation could affect Gulf traffic management.",
  explanation_bullets: [
    "This route's LHR–DXB leg transits the active Middle East advisory zone — a real exposure on the first 7-hour segment.",
    "The airspace exposure is real even though flights are currently operating normally. Don't overlook it when comparing options.",
    "Singapore Airlines also operates direct LHR–SIN (the alternative to this routing) if you want to eliminate the DXB connection point entirely.",
    "Emirates provides the highest frequency of any carrier on this corridor: 4 daily LHR–DXB departures gives strong rebooking options.",
    "DXB–SIN second leg is clean — no active advisory concerns on this segment."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: sin.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · 2 daily LHR–HKG–SIN",
  path_geojson: line.([[lhr.lng, lhr.lat], [52.0, 46.0], [85.0, 43.0], [hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
  distance_km: 12600, typical_duration_minutes: 890, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Gulf-free routing via Cathay's Hong Kong hub. Longer total journey but cleanest airspace profile of the three options.",
  ranking_context: "Structural score (57) is lower than Istanbul (73) because HKG sits east of SIN, creating a genuine backtrack — Singapore is south of Hong Kong, so you overshoot slightly. Pressure score (77) matches Istanbul. Net composite lands in Watchful but at the lower end.",
  watch_for: "LHR–HKG depends on the Central Asian corridor. If Eurocontrol issues flow restrictions before your flight, the first leg is the exposure point.",
  explanation_bullets: [
    "Both legs avoid the Middle East advisory zone entirely. LHR–HKG routes east via Central Asia; HKG–SIN routes south through South China Sea — a fully Gulf-free journey.",
    "The backtrack from HKG to SIN is real: Hong Kong lies ~2,600km north-northeast of Singapore, making this the longest total distance of the three options by ~1,400km.",
    "Cathay Pacific's HKG hub has strong resilience and excellent onward connectivity throughout Southeast Asia if SIN connections are needed.",
    "This option makes the most structural sense if Gulf risk is your primary concern and schedule flexibility allows for a 14-15 hour journey.",
    "Cathay operates 2 daily LHR–HKG departures with onward connections; rebooking depth is adequate but narrower than Emirates on the Dubai option."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Singapore (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → HONG KONG
# Three families: Turkey hub · Gulf · Central Asia
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: hkg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) / Cathay Pacific (CX)",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [hkg.lng, hkg.lat]]),
  distance_km: 9660, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Currently most reliable LHR→HKG option, but the IST–HKG leg depends heavily on the congested Central Asian corridor.",
  ranking_context: "Ranked above the Dubai option because it avoids the Middle East advisory zone. Main limitation is the Istanbul–HKG second leg, which goes through the congested Central Asian corridor with limited alternatives.",
  watch_for: "Check Eurocontrol Central Asian flow restriction status within 24 hours of departure for the IST–HKG leg. Flow restrictions on this segment cause delays of 30–90 minutes.",
  explanation_bullets: [
    "LHR–IST is clean and well-established. The IST–HKG segment then transits the Central Asian corridor — the congestion point for all non-Gulf Asia routings.",
    "The Central Asian corridor dependency (score 2/3) is the key structural risk: it is the single available path for this segment with limited flexibility if flow restrictions are applied.",
    "Cathay Pacific and Turkish Airlines both operate this pairing; combined frequency gives adequate but not exceptional rebooking depth.",
    "Istanbul hub carries a level-1 hub risk score — geographically proximate to regional instability but not currently operationally affected.",
    "Journey adds ~90 min versus pre-2022 Russia-overflight routing. Current schedule variance is higher than pre-2022 due to corridor congestion."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: hkg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Cathay Pacific (CX)",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [hkg.lng, hkg.lat]]),
  distance_km: 11200, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Avoids Central Asian corridor entirely but trades it for Middle East advisory zone exposure and a 2-hour distance penalty.",
  ranking_context: "Ranked below Istanbul: the London–Dubai leg crosses the active advisory zone, and the southerly routing adds ~2 hours. Best used as a backup when the Central Asian corridor is restricted.",
  watch_for: "Use this option proactively when Eurocontrol issues Central Asian flow restrictions affecting the Istanbul routing. Monitor Emirates disruption alerts if regional tensions escalate.",
  explanation_bullets: [
    "Routes south rather than east, bypassing the Central Asian congestion corridor entirely — making it the structural backup when that corridor is under flow restriction.",
    "LHR–DXB leg transits the Middle East advisory zone, which carries current elevated advisory status — this is the direct trade-off versus the Istanbul routing.",
    "Significantly longer routing: DXB–HKG routes northeast, adding approximately 2 hours versus the Istanbul option.",
    "Emirates provides high-frequency LHR–DXB service; rebooking depth for the first leg is the strongest of any option on this pair.",
    "DXB–HKG is a mature, uncongested segment with no active airspace concerns. The risk is entirely on the first leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asian Corridor (Direct)",
  carrier_notes: "British Airways (BA) · Cathay Pacific (CX) direct",
  path_geojson: line.([[lhr.lng, lhr.lat], [55.0, 48.0], [85.0, 45.0], [hkg.lng, hkg.lat]]),
  distance_km: 9550, typical_duration_minutes: 700, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Fastest total distance, but maximum single-corridor dependency. The entire route lives or dies on Central Asian corridor availability.",
  ranking_context: "The overall score looks reasonable, but the route is structurally the most fragile of the three: the entire journey depends on one corridor with no backup. Fastest on a normal day; most vulnerable if that corridor is restricted.",
  watch_for: "This is the highest-variance option. On good days it is the fastest. On days with Eurocontrol flow restrictions, it incurs the longest delays of any option. Check ATFM status before departure.",
  explanation_bullets: [
    "There's only one viable path for this route — the Central Asian corridor. If that's restricted, there's no practical alternative without switching to a completely different itinerary.",
    "British Airways and Cathay Pacific both operate direct LHR–HKG. On days without restrictions, this is the fastest option by 1–2 hours.",
    "The route avoids the Middle East advisory zone entirely, routing far north through Central Asian airspace.",
    "Eurocontrol data shows ATFM restrictions on this corridor multiple times per week — delay exposure is real and regular, not occasional.",
    "The overall score looks fine, but the corridor vulnerability is the real concern. If flow restrictions hit on your travel day, this route has no good exit."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Hong Kong (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → TOKYO
# Three families: Turkey hub · Gulf · North Asia (HKG)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: nrt.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) / Japan Airlines (JL)",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [55.0, 40.0], [90.0, 40.0], [nrt.lng, nrt.lat]]),
  distance_km: 12430, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Viable LHR→NRT option, but the IST–NRT leg fully traverses the Central Asian corridor — the longest exposure to that congestion bottleneck of any option on this pair.",
  ranking_context: "Ranks below the HKG option because the entire IST–NRT second leg depends on the Central Asian corridor. HKG routing via Cathay avoids it entirely on both legs.",
  watch_for: "Check Eurocontrol Central Asian ATFM status before each leg. Delays on the IST–NRT segment of 45–90 minutes are not unusual during peak restriction periods.",
  explanation_bullets: [
    "The IST–NRT segment (9 hours) runs entirely through the Central Asian corridor — the longest single-segment corridor dependency of any LHR–NRT option.",
    "Corridor dependency rated 2/3: there is no realistic alternative path for the Istanbul–Tokyo segment if the corridor is restricted.",
    "Turkish Airlines and Japan Airlines offer adequate combined frequency; Japan Airlines' NRT–IST service provides a solid connection option.",
    "Istanbul hub carries level-1 risk — within monitoring range of regional instability but not currently affecting operations.",
    "Journey is approximately 3.5 hours longer than pre-2022 direct Russia overflight routing — now 15+ hours total."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · LHR–HKG–NRT",
  path_geojson: line.([[lhr.lng, lhr.lat], [52.0, 46.0], [85.0, 43.0], [hkg.lng, hkg.lat], [nrt.lng, nrt.lat]]),
  distance_km: 13100, typical_duration_minutes: 940, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Best structural option for LHR→NRT. Cathay routes LHR–HKG via South Asia, bypassing the Central Asian corridor entirely. HKG–NRT is a clean northeast Asian segment.",
  ranking_context: "Ranks above Istanbul because corridor dependency is 1 vs 2 — Cathay's south Asian routing for LHR–HKG has genuine alternatives to the Central Asian bottleneck. The backtrack complexity (HKG is south of NRT) is the trade-off.",
  watch_for: "The HKG–NRT segment transits Chinese airspace. Monitor any PRC airspace developments. Note: Cathay Pacific is a Hong Kong carrier — any PRC policy changes to HKG operations would affect this option.",
  explanation_bullets: [
    "Cathay Pacific routes LHR–HKG via South Asia (southern corridor over India and South Asia), not through the Central Asian bottleneck — this is the key structural advantage over the Istanbul option.",
    "Corridor dependency rated 1/3: multiple routing options exist for LHR–HKG, versus the Istanbul option's sole dependency on Central Asian airspace.",
    "HKG hub is world-class in resilience. NRT is a stable destination. The HKG–NRT segment over the Pacific approaches is uncongested.",
    "Trade-off: HKG sits south-southwest of NRT, meaning this routing approaches Tokyo from below rather than the northwest. Total distance is ~700km longer than Istanbul option.",
    "Cathay Pacific's 2 daily LHR–HKG departures give adequate but not high-frequency rebooking options if disruption occurs."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: nrt.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Japan Airlines (JL) / ANA (NH)",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [nrt.lng, nrt.lat]]),
  distance_km: 13500, typical_duration_minutes: 975, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Use as a contingency when Central Asian corridor is restricted. Avoids the bottleneck entirely but adds Middle East airspace exposure and roughly 2 hours.",
  ranking_context: "Lowest-ranked here: the LHR–DXB leg crosses the active advisory zone, and this is also the longest of the three routings. Best kept as a contingency when the Central Asian corridor is restricted.",
  watch_for: "This option's value depends on whether Gulf escalation stays contained. If it doesn't, the relative advantage of avoiding Central Asia disappears while you take on Middle East exposure. Monitor both situations.",
  explanation_bullets: [
    "Avoids the Central Asian corridor completely — useful contingency when flow restrictions are severe on the Istanbul or HKG routings.",
    "LHR–DXB transits the Middle East advisory zone: this is the trade-off for avoiding Central Asian congestion.",
    "DXB–NRT is a very long segment (~8,000km). It routes north-northeast across China — well clear of any advisory zones but a very long single leg.",
    "Emirates provides high LHR–DXB frequency for the first leg; the DXB–NRT leg has adequate but limited frequency.",
    "Total journey exceeds 16 hours — the longest of the three LHR–NRT options. Reserve this for contingency use."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: nrt.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · 2 daily LHR–ICN, 10+ daily ICN–NRT",
  path_geojson: line.([[lhr.lng, lhr.lat], [60.0, 44.0], [icn.lng, icn.lat], [nrt.lng, nrt.lat]]),
  distance_km: 10800, typical_duration_minutes: 790, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Strong alternative to Via Istanbul. ICN hub scores 0/3 (world-class) and the ICN→NRT second leg is only 2.5 hours over clean Pacific airspace — much shorter than IST→NRT. First leg uses the Central Asian corridor.",
  ranking_context: "Ranks above Istanbul because ICN hub quality (0/3) beats IST (1/3), and the short second leg creates a cleaner risk profile than the 9-hour IST→NRT segment. Both options share the Central Asian corridor on the first leg.",
  watch_for: "LHR→ICN uses the Central Asian corridor — check Eurocontrol ATFM status before departure. ICN→NRT transits Korean and Japanese airspace: clean, uncongested, no active advisories.",
  explanation_bullets: [
    "ICN hub rated 0/3 (world-class) — Incheon is one of the world's most resilient transit hubs with excellent onward connections throughout Northeast Asia.",
    "The ICN→NRT second leg is only ~2.5 hours over clean Korean/Japanese airspace — dramatically shorter and less corridor-exposed than IST→NRT (~9 hours through Central Asia).",
    "LHR→ICN first leg uses the Central Asian corridor. This is the same exposure as the Istanbul option on the first leg — but the hub break at Seoul provides recovery optionality.",
    "Korean Air operates 2 daily LHR→ICN departures with 10+ daily ICN→NRT frequencies — strong second-leg rebooking depth.",
    "Total journey with a normal layover runs approximately 14.5 hours. On a clear day the direct BA/JAL flight is slightly faster; via Seoul offers a better hub."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: nrt.id, via_hub_city_id: pek.id,
  corridor_family: "china_arc",
  route_name: "Via Beijing",
  carrier_notes: "Air China (CA) · daily LHR–PEK–NRT",
  path_geojson: line.([[lhr.lng, lhr.lat], [55.0, 47.0], [85.0, 44.0], [pek.lng, pek.lat], [nrt.lng, nrt.lat]]),
  distance_km: 11000, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Air China's China-side option for LHR→NRT. PEK→NRT is a short, clean segment (~3 hours) over Yellow Sea airspace with no active advisories. The LHR→PEK first leg uses the Central Asian corridor — same structural dependency as Istanbul.",
  ranking_context: "Scores similarly to Istanbul because both use the Central Asian corridor on the first leg and both hubs carry a 1/3 hub risk. The difference is the hub and carrier: Air China's Beijing hub adds PRC political context; Istanbul adds regional proximity to Middle East tensions. PEK→NRT is a shorter second leg than IST→NRT.",
  watch_for: "LHR→PEK uses the Central Asian corridor — check ATFM restrictions before departure. Monitor PRC aviation policy for any bilateral route changes affecting Air China's London service.",
  explanation_bullets: [
    "Air China operates daily LHR→PEK direct service, connecting to multiple daily PEK→NRT frequencies — this is a real, high-frequency corridor option, not a workaround.",
    "PEK→NRT is only ~3 hours over clean Yellow Sea/East China Sea airspace with no active airspace advisories.",
    "LHR→PEK first leg uses Central Asian corridor — the same routing constraint shared by the Istanbul and Via Seoul options.",
    "Beijing hub rated 1/3: major hub with strong operational resilience, but PRC political and regulatory context means bilateral route access warrants monitoring.",
    "Total journey runs approximately 13.5 hours — comparable to Istanbul routing. The China-side routing may suit travelers with Air China status, flexible fares, or China stopovers."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Tokyo (5 corridor families: IST, HKG, DXB, ICN/Seoul, Beijing/china_arc)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → SINGAPORE
# Three families: Turkey hub · Gulf · North Asia (HKG)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) / Singapore Airlines (SQ)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 10880, typical_duration_minutes: 795, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Leading option for FRA→SIN. Avoids both the Middle East advisory zone and Central Asian corridor dependency on both legs.",
  ranking_context: "Top option for FRA–SIN: avoids the Middle East advisory zone on both legs and doesn't overshoot Singapore. The IST–SIN leg routes south via Pakistan/India with minimal active advisory exposure.",
  watch_for: "Singapore Airlines operates a direct FRA–SIN service that bypasses Istanbul entirely. If you want to eliminate the hub connection risk, SQ direct is worth comparing.",
  explanation_bullets: [
    "FRA–IST uses standard central European routing — no restricted airspace. IST–SIN routes east through Pakistan/India to Singapore with level-1 airspace exposure.",
    "Lufthansa, Turkish Airlines, and Singapore Airlines all operate on this pairing via Istanbul; combined frequency gives strong rebooking options.",
    "IST hub sits outside the Middle East advisory zone and has not experienced operational disruption related to regional tensions.",
    "Singapore Airlines also operates FRA–SIN direct (no connection) — compare this as an alternative if you want to reduce hub dependency.",
    "Journey is ~13 hours — well-established post-2022 routing with low time variance."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) / Singapore Airlines (SQ)",
  path_geojson: line.([[fra.lng, fra.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
  distance_km: 11560, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency option, but the FRA–DXB leg crosses the active Middle East advisory zone. Strong rebooking options, but the airspace exposure is real.",
  ranking_context: "Ranked below Istanbul because the FRA–DXB leg crosses the advisory zone. Ranked above HKG because Dubai sits more directly on the route to Singapore — less backtracking.",
  watch_for: "Emirates operates 5+ daily FRA–DXB services. If disruption hits the first leg, rebooking options are stronger here than on any other option for this pair.",
  explanation_bullets: [
    "FRA–DXB leg transits the active Middle East advisory zone — this is a real pressure factor, not a background note.",
    "The airspace exposure on the first leg is the defining risk of this routing — even though operations are currently normal.",
    "Emirates' very high FRA–DXB frequency (5+ daily) provides the strongest rebooking depth of any option on this pair, if disruption forces a change.",
    "DXB–SIN is a clean, well-established segment with no active advisory concerns.",
    "Total journey approximately 45 minutes longer than Istanbul option due to more southerly geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: sin.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Lufthansa (LH) + Cathay Pacific (CX) / Singapore Airlines (SQ)",
  path_geojson: line.([[fra.lng, fra.lat], [52.0, 47.0], [85.0, 43.0], [hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
  distance_km: 12700, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Avoids Gulf entirely and delivers excellent pressure score, but the routing overshoots Singapore significantly — HKG is north-northeast of SIN.",
  ranking_context: "Same clean airspace profile as Istanbul — neither leg touches the advisory zone. Ranked lower because HKG sits north-northeast of SIN, creating a real backtrack of ~2,600km. Best when avoiding Gulf exposure on both legs matters more than efficiency.",
  watch_for: "FRA–HKG may use Central Asian or South Asian routing depending on the carrier. Confirm with Cathay Pacific before booking if corridor exposure matters to you.",
  explanation_bullets: [
    "Neither leg touches the Middle East advisory zone. FRA–HKG routes east; HKG–SIN routes south — a fully Gulf-free journey.",
    "The HKG→SIN segment involves meaningful backtrack: HKG is ~2,600km north of SIN, making this the longest total distance option by ~1,800km versus Istanbul.",
    "HKG hub is world-class; Cathay Pacific's network is strong. Singapore Airlines has excellent SIN hub connectivity for onward travel.",
    "This option is most valuable when Gulf escalation drives you to avoid the Middle East advisory zone on both legs, not just one.",
    "Consider Singapore Airlines' FRA–SIN direct as a cleaner alternative that avoids both hub dependency and the HKG backtrack."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Singapore (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → TOKYO
# Three families: Central Asia (direct) · Turkey hub · North Asia (HKG via south)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asian Corridor (Direct)",
  carrier_notes: "Air France (AF) direct — rerouted via Central Asia since 2022",
  path_geojson: line.([[cdg.lng, cdg.lat], [50.0, 42.0], [80.0, 47.0], [nrt.lng, nrt.lat]]),
  distance_km: 11850, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 2, operational_score: 1,
  recommendation_text: "Weakest option for CDG→NRT. Sole-corridor dependency on Central Asian airspace at maximum rating. On good days the fastest; on restriction days the most delayed.",
  ranking_context: "Weakest structural option of the three: the entire route depends on one corridor with no backup. If it's restricted on your travel day, you're stuck. Airspace is clear — the risk is entirely congestion and flow restrictions.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before every departure. Air France has reduced CDG–NRT frequency since 2022 — verify current schedule before booking.",
  explanation_bullets: [
    "Corridor dependency is 3/3 — the maximum rating. The entire CDG–NRT routing goes through the Central Asian corridor with no alternative path. If the corridor is restricted, this flight delays.",
    "Air France has reduced CDG–NRT frequency relative to 2022 levels due to the rerouting economics. Options are more limited if rebooking is needed.",
    "Pre-2022, CDG–NRT overflew Russia in ~12 hours. Current routing via Central Asia runs 13–15 hours depending on flow restriction delays.",
    "The route looks acceptable overall, but it's structurally fragile — the whole journey goes through one corridor with no alternative. Treat it as a high-variance option, not a safe default.",
    "Japan Airlines operates CDG–NRT via an alternative routing that may have lower corridor dependency — compare JL's routing before defaulting to Air France."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: nrt.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) / Japan Airlines (JL)",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [55.0, 40.0], [90.0, 40.0], [nrt.lng, nrt.lat]]),
  distance_km: 12400, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Better structural resilience than the direct Central Asian routing by breaking the journey at Istanbul. IST–NRT still uses Central Asian corridor, but the hub break gives routing flexibility.",
  ranking_context: "Ranks between Central Asian direct (42 structural) and HKG via south (72 structural). The Istanbul hub break means the two-leg structure allows rerouting on the second leg if the first is disrupted — an advantage the direct flight lacks.",
  watch_for: "IST–NRT second leg traverses the Central Asian corridor — same exposure point as the direct flight, but you have a natural decision point at Istanbul to assess conditions before continuing.",
  explanation_bullets: [
    "Splitting at Istanbul creates a decision point: if conditions deteriorate before the Istanbul layover, you can reassess your onward routing rather than being committed to a direct 14-hour flight.",
    "Corridor dependency rated 2/3 (not 3/3 like the direct) because the Istanbul hub creates structural flexibility: the second leg can theoretically be rerouted south if needed.",
    "IST hub adds mild regional risk (level-1 hub score) but provides Japan Airlines and Turkish Airlines connections with adequate frequency.",
    "This option is ~30 minutes longer than the HKG option but requires less backtrack — it is the middle ground between direct-corridor risk and southerly-routing distance.",
    "Turkey-Japan connectivity has been stable; Japan Airlines' NRT–IST direct service makes this a reliable connection pathway."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong (Cathay South Routing)",
  carrier_notes: "Cathay Pacific (CX) — routes CDG–HKG via South Asia, avoiding Central Asian corridor",
  path_geojson: line.([[cdg.lng, cdg.lat], [45.0, 30.0], [80.0, 20.0], [hkg.lng, hkg.lat], [nrt.lng, nrt.lat]]),
  distance_km: 13200, typical_duration_minutes: 945, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Best structural resilience for CDG→NRT. Cathay routes CDG–HKG south via the Middle East/South Asia corridor, bypassing Central Asian congestion entirely. Trade-off: longer distance and Middle East advisory exposure on the first leg.",
  ranking_context: "Best structural resilience of the three — Cathay's south routing gives genuine alternative paths, unlike the one-corridor dependency on the Central Asian route. The trade-off is that the first leg crosses the Middle East advisory zone.",
  watch_for: "Confirm with Cathay Pacific that the CDG–HKG routing is south via India and not east via Central Asia — Cathay does route-select based on conditions and may change. Also: HKG–NRT transits Chinese airspace; monitor PRC airspace policy.",
  explanation_bullets: [
    "Cathay Pacific routes CDG–HKG via the southern corridor (over the Middle East and South Asia), entirely bypassing the Central Asian congestion bottleneck — the critical structural advantage of this option.",
    "Corridor dependency rated 1/3: the south Asian routing has multiple alternative sub-paths (Arabian Sea vs Bay of Bengal) versus the Central Asian sole-corridor structure.",
    "The CDG–HKG leg transits the Middle East advisory zone — that's the direct trade-off for avoiding Central Asian congestion.",
    "HKG–NRT is a clean northeast Asian segment via East China Sea. HKG hub is world-class; NRT arrival is uncongested.",
    "Total journey is the longest of the three options (~15.5 hours) due to the southerly detour — the price of the structural resilience advantage."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: nrt.id, via_hub_city_id: pek.id,
  corridor_family: "china_arc",
  route_name: "Via Beijing",
  carrier_notes: "Air China (CA) · daily CDG–PEK–NRT",
  path_geojson: line.([[cdg.lng, cdg.lat], [50.0, 46.0], [85.0, 44.0], [pek.lng, pek.lat], [nrt.lng, nrt.lat]]),
  distance_km: 10500, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Air China's China-side option for CDG→NRT. PEK→NRT is a short, clean segment (~3 hours) over Yellow Sea airspace. The CDG→PEK first leg uses the Central Asian corridor — same structural constraint as Via Istanbul on this pair.",
  ranking_context: "Ranks above the direct Central Asian routing (single corridor dependency) and on par with Via Istanbul. Better than the direct because the hub break at Beijing creates a reroute decision point. Ranks below Cathay's south routing for structural resilience, but avoids the Middle East advisory zone exposure that the HKG option carries on its first leg.",
  watch_for: "CDG→PEK uses the Central Asian corridor — check Eurocontrol ATFM status before departure. Monitor Air China CDG–PEK bilateral route access; PRC aviation policy can affect service frequency.",
  explanation_bullets: [
    "Air China operates daily CDG→PEK service connecting to multiple daily PEK→NRT frequencies — a real high-frequency corridor option.",
    "PEK→NRT is only ~3 hours over clean Yellow Sea/East China Sea airspace with no active airspace advisories.",
    "CDG→PEK first leg uses the Central Asian corridor — the same constraint as Via Istanbul, but the hub break at Beijing creates a natural decision point before committing to the second leg.",
    "Beijing hub rated 1/3: major hub with strong operational resilience, but PRC political and regulatory context warrants monitoring.",
    "Total journey approximately 15 hours — slightly longer than Via Istanbul due to CDG's westerly position, but airspace exposure profile is similar."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Tokyo (4 corridor families: central_asia, IST, HKG, beijing/china_arc)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → SINGAPORE
# Three families: Turkey hub · Gulf (KLM direct) · North Asia (HKG)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK) / Singapore Airlines (SQ)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 11010, typical_duration_minutes: 795, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for AMS→SIN. Avoids the Middle East advisory zone on both legs. KLM's AMS–IST connection is among the most frequent European feeders into Turkish Airlines' IST–SIN service.",
  ranking_context: "Top option here: avoids the Middle East advisory zone on both legs and has the most structural flexibility. The KLM non-stop avoids the hub connection but crosses the advisory zone on its direct route.",
  watch_for: "Singapore Airlines operates SIN direct from AMS — compare SQ's non-stop if eliminating hub dependency matters.",
  explanation_bullets: [
    "AMS–IST uses standard Central European routing — no advisory exposure. IST–SIN routes east via South Asia with level-1 airspace peripheral exposure.",
    "KLM and Singapore Airlines have codeshare depth on this pairing; Turkish Airlines adds capacity. Frequency is strong.",
    "Journey is consistently ~13 hours. Istanbul hub has shown no operational disruption from regional tensions as of last review.",
    "The IST–SIN second leg routes over Iran/Pakistan: level-1 exposure, monitored but no current routing restriction.",
    "This is the structurally simplest viable routing for AMS–SIN under current airspace conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "KLM Direct",
  carrier_notes: "KLM (KL) — non-stop AMS–SIN, routes south via Middle East",
  path_geojson: line.([[ams.lng, ams.lat], [45.0, 30.0], [75.0, 15.0], [sin.lng, sin.lat]]),
  distance_km: 10850, typical_duration_minutes: 775, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "No hub connection needed — cleanest journey structure. Trade-off is Middle East advisory zone transit and a single-carrier dependency on KLM.",
  ranking_context: "Cleanest journey structure — no hub, no connection. The trade-off is that the route crosses the Middle East advisory zone and KLM is the only non-stop operator, so rebooking options are limited if disrupted.",
  watch_for: "KLM is the sole carrier on AMS–SIN non-stop. If KLM suspends or delays this service, there is no immediate alternative non-stop. The Istanbul connection option becomes your fallback.",
  explanation_bullets: [
    "Non-stop means no missed connection risk, no hub vulnerability, no layover — structurally the simplest option with the lowest connection-point count.",
    "KLM routes AMS–SIN via the Middle East advisory zone — same southern corridor as the Gulf options. This is the trade-off for avoiding a connection.",
    "Operational score of 1 reflects single-carrier exposure: KLM is the only non-stop operator. If the flight is disrupted, you are rebooking onto a connection service.",
    "The entire non-stop route passes through the Middle East advisory zone — that's the primary risk factor on this option.",
    "Fastest option by elapsed time when operating normally. On disruption days, lack of alternative non-stop operators makes this harder to recover."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: sin.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "KLM (KL) + Cathay Pacific (CX) / Singapore Airlines (SQ)",
  path_geojson: line.([[ams.lng, ams.lat], [52.0, 47.0], [85.0, 43.0], [hkg.lng, hkg.lat], [sin.lng, sin.lat]]),
  distance_km: 12500, typical_duration_minutes: 885, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Gulf-free option that matches Istanbul on pressure score but incurs a significant distance penalty due to HKG backtrack.",
  ranking_context: "Same clean airspace as Istanbul — neither leg touches the advisory zone. Ranked lower because HKG sits northeast of SIN, adding ~1,500km to the journey. Choose this when avoiding Gulf exposure on both legs matters more than efficiency.",
  watch_for: "AMS–HKG routing depends on whether the carrier uses Central Asian or South Asian corridor. Clarify before booking. HKG–SIN backtrack is ~2,600km — factor into total journey time.",
  explanation_bullets: [
    "Both legs stay outside the Middle East advisory zone, making this the best pressure-profile option alongside Istanbul.",
    "The backtrack from HKG to SIN adds ~1,500km versus the Istanbul option — HKG is northeast of SIN, requiring a southward correction on the second leg.",
    "HKG hub is excellent; Cathay Pacific's regional network in Southeast Asia is robust if onward connections are needed beyond SIN.",
    "This option makes sense primarily as a strategic choice to avoid Gulf exposure on both legs, not as a default based on efficiency.",
    "Total journey time approaches 14.5 hours — the longest of the three AMS–SIN options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Singapore (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → KUALA LUMPUR
# Three families: Turkey hub · Gulf · North Asia (HKG)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: kul.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK) / Malaysia Airlines (MH)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [kul.lng, kul.lat]]),
  distance_km: 10540, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Most reliable AMS→KUL corridor. Avoids Gulf exposure; Istanbul hub stable and well-connected to Kuala Lumpur.",
  ranking_context: "Top option here: avoids the Middle East advisory zone and doesn't involve backtracking. Kuala Lumpur sits in a natural line between Istanbul and the destination, so the geometry works in its favour.",
  watch_for: "KLM operates AMS–KUL direct as an alternative — compare if eliminating hub connection risk is a priority.",
  explanation_bullets: [
    "AMS–IST avoids all advisory zones; IST–KUL routes east via South Asia with level-1 peripheral exposure.",
    "Turkish Airlines and Malaysia Airlines both serve IST–KUL; combined frequency provides adequate rebooking options.",
    "Kuala Lumpur (KUL) hub is fully operational with no disruption factors.",
    "KLM also operates AMS–KUL non-stop — consider this if hub connection risk outweighs the Middle East advisory exposure.",
    "This routing is geometrically efficient: Istanbul is well-positioned between Amsterdam and Kuala Lumpur, minimising detour."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: kul.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Malaysia Airlines (MH)",
  path_geojson: line.([[ams.lng, ams.lat], [dxb.lng, dxb.lat], [kul.lng, kul.lat]]),
  distance_km: 11100, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency option with strong rebooking depth, but the AMS–DXB leg crosses the Middle East advisory zone.",
  ranking_context: "Ranks below Istanbul (Watchful 60 vs 75) due to Middle East advisory exposure. Pressure score (53) is Constrained — the airspace risk on the first leg is material.",
  watch_for: "Monitor Gulf and Levant regional developments. The Middle East advisory zone's current elevated status makes this leg higher-risk than Gulf routing was pre-2024.",
  explanation_bullets: [
    "AMS–DXB transits the active Middle East advisory zone — the same structural risk as on London and Frankfurt Gulf routes.",
    "Emirates' high AMS–DXB frequency provides the best rebooking options of any option if disruption occurs on the first leg.",
    "DXB–KUL is a clean, high-frequency segment with no active advisory concerns.",
    "Pressure score of 53 (Constrained range) should be noted even though the composite is Watchful.",
    "Total journey is approximately 30 minutes longer than Istanbul option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: kul.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "KLM (KL) + Cathay Pacific (CX) / Malaysia Airlines (MH)",
  path_geojson: line.([[ams.lng, ams.lat], [52.0, 47.0], [85.0, 43.0], [hkg.lng, hkg.lat], [kul.lng, kul.lat]]),
  distance_km: 12200, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Gulf-free routing via HKG. Pressure score matches Istanbul (77). Structural score lower (57) due to HKG backtrack — KUL is south-southwest of HKG.",
  ranking_context: "Pressure profile matches Istanbul but structural score trails. The backtrack from HKG down to KUL is the main penalty. Worth choosing if Gulf exposure on both legs is the primary concern.",
  watch_for: "AMS–HKG may use Central Asian corridor (corridor dependency 2). Confirm routing with carrier. HKG–KUL is a clean 3-hour segment.",
  explanation_bullets: [
    "Both legs avoid Middle East advisory zone: AMS–HKG routes east, HKG–KUL routes south — a fully Gulf-free journey.",
    "Corridor dependency rated 2/3 because AMS–HKG may use the Central Asian corridor depending on carrier and conditions.",
    "HKG hub is world-class. KUL destination hub is fully operational.",
    "The backtrack from HKG to KUL adds approximately 1,100km to the journey versus a more direct routing.",
    "Use this option primarily when Gulf avoidance on both legs is the priority over journey efficiency."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Kuala Lumpur (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → HONG KONG
# Three families: Turkey hub · Gulf · Central Asia
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: hkg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) / Cathay Pacific (CX)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [hkg.lng, hkg.lat]]),
  distance_km: 9490, typical_duration_minutes: 705, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Most reliable FRA→HKG option, but the IST–HKG leg uses the Central Asian corridor — the primary structural vulnerability.",
  ranking_context: "Ranks above Gulf option on pressure (77 vs 53). Corridor dependency of 2/3 on the IST–HKG segment is the defining structural weakness shared with the Istanbul option on all Asian long-haul routes.",
  watch_for: "Eurocontrol Central Asian ATFM status should be checked within 24 hours of departure. The IST–HKG leg is the exposure point.",
  explanation_bullets: [
    "FRA–IST is clean. IST–HKG then traverses the Central Asian corridor — where the structural fragility lies.",
    "Corridor dependency rated 2/3: the Central Asian bottleneck is the single viable path for the Istanbul–Hong Kong segment.",
    "Lufthansa and Cathay Pacific offer adequate combined frequency. IST hub is stable.",
    "Journey adds ~90 min versus pre-2022 Russia overflight timing. Current variance is higher than historical due to corridor congestion.",
    "If Eurocontrol restricts Central Asian flow on your departure day, the IST–HKG leg is the delay point."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: hkg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) / Cathay Pacific (CX)",
  path_geojson: line.([[fra.lng, fra.lat], [dxb.lng, dxb.lat], [hkg.lng, hkg.lat]]),
  distance_km: 11230, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Avoids Central Asian congestion but adds Middle East advisory exposure and significant distance. Best used as a contingency when Central Asian flow restrictions are active.",
  ranking_context: "Structural score (55) is the lowest of the three options because both Gulf exposure (2) and routing complexity (2) are elevated. Composite 55 sits right at the Constrained boundary — read both the structural (55) and pressure (53) scores before booking.",
  watch_for: "Both structure and pressure are at their lowest for FRA–HKG on this option. Use only when the Istanbul routing faces confirmed Central Asian flow restrictions.",
  explanation_bullets: [
    "Avoids Central Asian corridor entirely — the structural advantage over the Istanbul option when that corridor is restricted.",
    "FRA–DXB transits the Middle East advisory zone: this is the trade-off, and current advisory status makes this meaningful.",
    "Routing complexity rated 2/3: DXB–HKG requires a northeast track of ~7,400km — very long second leg with significant geometry.",
    "Composite score of 55 approaches Constrained territory. Both structural (55) and pressure (53) scores are in the Constrained band.",
    "Emirates provides strong FRA–DXB rebooking options. The DXB–HKG segment has fewer operators and less schedule flexibility."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Lufthansa Direct (Central Asian Routing)",
  carrier_notes: "Lufthansa (LH) direct FRA–HKG via Central Asian corridor",
  path_geojson: line.([[fra.lng, fra.lat], [50.0, 47.0], [80.0, 44.0], [hkg.lng, hkg.lat]]),
  distance_km: 9250, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Shortest total distance, but sole-corridor dependency at maximum rating. Fastest on normal days; most vulnerable when Central Asian corridor is restricted.",
  ranking_context: "Structural score (55) is the lowest of the three because corridor dependency is 3/3. Pressure score (60) is moderate. Composite (58) places this as Watchful, but the structural score alone is Constrained — the fragility is real.",
  watch_for: "Sole-corridor route. Any Eurocontrol Central Asian ATFM restriction on departure day directly affects this flight. Check ATFM status before every departure.",
  explanation_bullets: [
    "Corridor dependency rated 3/3 — the highest possible. The entire flight uses the Central Asian corridor with no viable reroute option.",
    "On days without flow restrictions, this is the most direct and time-efficient option for FRA–HKG.",
    "Lufthansa has adjusted FRA–HKG frequency since 2022; verify current schedule. Single-carrier direct means limited rebooking alternatives.",
    "Structural score of 55 is in the Constrained range — this route's fragility should be treated as a primary booking consideration, not a background note.",
    "No hub means no connection risk — but also no natural reroute option if the flight is disrupted. You restart from Frankfurt."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Hong Kong (3 corridor families)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → DELHI  (2 families: direct Gulf · Turkey hub)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct via Gulf Corridor",
  carrier_notes: "British Airways (BA) · Air India (AI) · Virgin Atlantic (VS)",
  path_geojson: line.([[lhr.lng, lhr.lat], [45.0, 32.0], [del.lng, del.lat]]),
  distance_km: 6740, typical_duration_minutes: 510, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Direct LHR–DEL continues to operate reliably across all three carriers. The Middle East advisory zone transit on the long direct leg is the principal risk factor.",
  ranking_context: "Structural score is high (85) because direct routing eliminates all hub dependency and complexity. Pressure score (53 — Constrained) reflects the Middle East advisory zone transit on the full ~8-hour sector.",
  watch_for: "The Middle East advisory zone current status is Elevated (High severity). If regional conditions deteriorate significantly, this routing carries direct airspace exposure. Monitor UK FCDO advisories before travel.",
  explanation_bullets: [
    "Structural profile is excellent: direct routing with no hub, no connections, no corridor congestion dependency. This is the simplest possible journey structure.",
    "The entire LHR–DEL direct route transits the Middle East advisory zone — a ~4-hour exposure on the long mid-sector. This is the route's primary and only meaningful risk factor.",
    "Three carriers (BA, AI, VS) operate LHR–DEL non-stop with combined daily frequency of 6+ departures. Rebooking options are among the best on any long-haul pair.",
    "Pressure score of 53 (Constrained) reflects that the Middle East advisory zone has been elevated to High severity — meaningfully more pressured than 12 months ago.",
    "Delhi (DEL) hub is fully operational and a very stable destination. The risk is entirely on the outbound airspace, not the destination."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: del.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [del.lng, del.lat]]),
  distance_km: 8190, typical_duration_minutes: 630, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Reduces Middle East airspace exposure at the cost of a hub connection and 2 additional hours. Justified if current advisory zone escalation is your primary concern.",
  ranking_context: "Pressure score (77) is materially better than the direct option (53) because this routing avoids the Middle East advisory zone on both legs. Structural score is lower (63 vs 85) because of hub dependency and added complexity. The trade-off is explicit: less airspace pressure for more structural complexity.",
  watch_for: "IST–DEL second leg routes over Iran/Pakistan — level-1 airspace exposure. This is lower than the direct Gulf transit, but not zero.",
  explanation_bullets: [
    "Routing via Istanbul avoids the Middle East advisory zone on both legs: LHR–IST goes east via southeastern Europe, IST–DEL routes via Iran/Pakistan with only peripheral advisory exposure.",
    "Pressure score advantage (77 vs 53) is the strongest argument for this option versus the direct flight — it reflects a meaningful reduction in current airspace exposure.",
    "Adding a hub introduces connection risk: if the LHR–IST leg is delayed, you may miss the IST–DEL connection. Turkish Airlines' IST hub efficiency mitigates this but doesn't eliminate it.",
    "Journey is approximately 2 hours longer than direct — 10.5 vs 8.5 hours. This is the structural cost of the pressure reduction.",
    "Consider this option when UK FCDO or airline advisories flag elevated concern for the Gulf corridor specifically."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Delhi (2 corridor families — limited coverage noted)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → MUMBAI  (2 families: direct Gulf · Turkey hub)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct via Gulf Corridor",
  carrier_notes: "British Airways (BA) · Air India (AI) · Virgin Atlantic (VS)",
  path_geojson: line.([[lhr.lng, lhr.lat], [44.0, 30.0], [bom.lng, bom.lat]]),
  distance_km: 7190, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Direct LHR–BOM continues normally across multiple carriers. Structurally excellent; pressure is the primary concern given Middle East advisory zone transit.",
  ranking_context: "Structural score 85 — direct routing, no hub, strong multi-carrier frequency. Pressure score 53 (Constrained range) because the entire ~9-hour sector transits Middle East advisory zone.",
  watch_for: "Middle East advisory zone is currently at elevated severity. Monitor UK FCDO advisories. Any airspace restriction affecting the overflight sector would require rerouting — a low-probability but high-impact event.",
  explanation_bullets: [
    "Three carriers with 6+ daily combined departures make this one of the most frequency-dense long-haul pairs ex-London.",
    "Direct routing — no hub, no connection, no corridor dependency beyond the overflown airspace.",
    "The LHR–BOM sector spends approximately 5 hours transiting the Middle East advisory zone at current severity levels.",
    "Mumbai (BOM) hub is fully operational — no destination-side disruption risk.",
    "Pressure score of 53 (Constrained) reflects the current elevated advisory severity in the Middle East zone — meaningfully higher than 2023 baseline."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: bom.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [bom.lng, bom.lat]]),
  distance_km: 8400, typical_duration_minutes: 645, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Meaningfully reduces Middle East airspace exposure vs the direct option. Worth choosing if current advisory zone status is your primary concern.",
  ranking_context: "Pressure score jumps from 53 to 77 by avoiding the advisory zone — a 24-point improvement. The cost is 2 extra hours and a hub stop. Mumbai is a closer destination than Delhi, which makes the time penalty more noticeable for LHR→BOM than for longer pairs.",
  watch_for: "IST–BOM routes over Iran. Level-1 advisory — lower than Gulf direct, but not zero airspace exposure on the second leg.",
  explanation_bullets: [
    "Routing via Istanbul avoids the main Middle East advisory zone transit — both LHR–IST and IST–BOM routes stay outside the highest-severity areas.",
    "Pressure score improves from 53 to 77 — a 24-point improvement versus the direct option, which is material.",
    "Hub connection introduces standard risks: connection timing, missed-flight exposure. Turkish Airlines' IST operations are generally reliable.",
    "Journey approximately 2 hours longer: 10.5 vs 8.5 hours. Same structural cost as LHR–DEL via Istanbul.",
    "Consider this explicitly when UK FCDO elevates advisory severity for Gulf airspace or when airlines issue voluntary routing advisories."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Mumbai (2 corridor families — limited coverage noted)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → DELHI  addition: Via Dubai (third family)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: del.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Air India (AI)",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [del.lng, del.lat]]),
  distance_km: 8500, typical_duration_minutes: 640, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Highest rebooking flexibility via Emirates, but the LHR–DXB leg crosses the active Middle East advisory zone. Use when Istanbul is sold out or disrupted.",
  ranking_context: "Scores below Istanbul (63 vs 72) because the Gulf leg adds advisory zone exposure. Scores above the direct flight on pressure (53 vs 53) — same pressure exposure but the hub break gives more recovery options.",
  watch_for: "LHR–DXB crosses the active advisory zone. Emirates has 4+ daily LHR–DXB departures — best rebooking depth of the three options if disruption hits.",
  explanation_bullets: [
    "Emirates operates 4+ daily LHR–DXB departures, giving the strongest rebooking options of any LHR–DEL corridor if disruption forces a change.",
    "LHR–DXB transits the active Middle East advisory zone — the same exposure as the direct flight but with a hub stop added.",
    "DXB–DEL is a very short, clean segment (~3 hours) with no advisory concerns.",
    "Ranking: Istanbul reduces airspace exposure. Direct eliminates hub dependency. Dubai offers maximum schedule flexibility as the rebooking fallback."
  ],
  calculated_at: now
})

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → MUMBAI  addition: Via Dubai (third family)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: bom.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Air India (AI)",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [bom.lng, bom.lat]]),
  distance_km: 9000, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Strong frequency and rebooking depth via Emirates, but the LHR–DXB first leg crosses the active advisory zone. Best used as a backup when Istanbul is unavailable.",
  ranking_context: "Ranks below Istanbul (63 vs 72) due to advisory zone exposure on the first leg. Scores above direct on pressure recovery flexibility — the hub break allows rebooking at DXB if the LHR segment is disrupted.",
  watch_for: "LHR–DXB crosses the active advisory zone. Monitor Gulf escalation. Emirates' high frequency at DXB is the best contingency option on this pair.",
  explanation_bullets: [
    "Emirates offers 4+ daily LHR–DXB departures — the strongest first-leg rebooking depth of the three LHR–BOM options.",
    "LHR–DXB transits the active Middle East advisory zone, same as the direct routing.",
    "DXB–BOM is a short (~3 hour), clean segment with no advisory exposure.",
    "This option sits between Istanbul (best pressure) and direct (no hub dependency) — best chosen when high rebooking flexibility is the priority."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Delhi and Mumbai expanded to 3 corridor families")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → BANGKOK
# Three families: Turkey hub · Gulf (Dubai) · Gulf (Doha)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9200, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest option for FRA→BKK. Avoids the Middle East advisory zone on both legs. Lufthansa connects well to Turkish Airlines' IST–BKK service.",
  ranking_context: "Top option for FRA→BKK: avoids the advisory zone on both legs and the FRA–IST leg is tight geometry with no detour. Both FRA–IST and IST–BKK are among Turkish Airlines' highest-frequency routes, giving strong rebooking depth at both ends.",
  watch_for: "Check Turkish Airlines' IST operations if Turkey experiences regional turbulence. TK has 4+ daily IST–BKK departures — rebooking depth is strong.",
  explanation_bullets: [
    "FRA–IST uses standard central European routing — no advisory exposure. IST–BKK routes east with level-1 peripheral exposure.",
    "Istanbul hub sits well clear of the Middle East advisory zone and has not seen operational disruption from regional tensions.",
    "Lufthansa feeds into IST with multiple daily FRA–IST departures; combined frequency with TK gives solid rebooking options.",
    "Journey is consistently ~11.5 hours — one of the more time-efficient one-stop options for this pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK)",
  path_geojson: line.([[fra.lng, fra.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9900, typical_duration_minutes: 740, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High frequency via Emirates, but the FRA–DXB leg crosses the active Middle East advisory zone. Use as backup when Istanbul is disrupted or sold out.",
  ranking_context: "Ranked below Istanbul because the Frankfurt–Dubai leg crosses the advisory zone. Emirates provides the strongest rebooking depth on this pair if disruption forces a change.",
  watch_for: "Monitor Middle East advisory zone escalation. Emirates has 5+ daily FRA–DXB departures — best first-leg rebooking depth of any option.",
  explanation_bullets: [
    "FRA–DXB transits the active Middle East advisory zone — real exposure on the first 6-hour segment.",
    "Emirates' high FRA frequency means rebooking options are strong if the first leg is disrupted.",
    "DXB–BKK is a clean, well-operated segment with no active advisory concerns.",
    "Journey roughly 45–60 minutes longer than the Istanbul option due to the more southerly geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: bkk.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR)",
  path_geojson: line.([[fra.lng, fra.lat], [c["Doha"].lng, c["Doha"].lat], [bkk.lng, bkk.lat]]),
  distance_km: 9700, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Same advisory zone exposure as the Dubai option; slightly more geographically direct. Choose based on QR preference or schedule fit.",
  ranking_context: "Equal to the Dubai option on all measured factors. Doha sits slightly more directly between Frankfurt and Bangkok than Dubai, but the difference is minor. Choose based on airline preference.",
  watch_for: "FRA–DOH crosses the same advisory zone as FRA–DXB. Doha hub is close to the Levant situation — monitor QR operational alerts if regional tensions rise.",
  explanation_bullets: [
    "Qatar Airways operates FRA–DOH–BKK with good daily frequency — a genuine alternative to Emirates on this pair.",
    "FRA–DOH first leg crosses the Middle East advisory zone, same exposure as the Dubai option.",
    "DOH hub is world-class with strong Southeast Asia connectivity; DOH–BKK is an uncongested segment.",
    "Slightly shorter total distance than the Dubai routing due to Doha's more easterly position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Bangkok (3 corridor families: IST, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → BANGKOK
# Three families: Turkey hub · Gulf (Dubai) · Gulf (Doha)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9300, typical_duration_minutes: 690, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for AMS→BKK. Avoids Gulf exposure on both legs. KLM feeds well into Istanbul for Turkish Airlines' BKK service.",
  ranking_context: "Top option: avoids the advisory zone on both legs and has solid combined frequency with KLM and Turkish Airlines.",
  watch_for: "IST–BKK routes east via Iran/Pakistan — level-1 peripheral advisory. If Iran escalates short-notice NOTAMs, the IST–BKK leg may need mid-route adjustment. TK has 4+ daily IST–BKK services, giving strong rebooking depth.",
  explanation_bullets: [
    "AMS–IST avoids all advisory exposure; IST–BKK routes east with peripheral level-1 exposure only.",
    "KLM operates multiple daily AMS–IST departures connecting into Turkish Airlines' IST–BKK service.",
    "Istanbul hub sits well outside the active Middle East advisory zone.",
    "Journey is ~11.5 hours — efficient one-stop routing for this pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "KLM (KL) + Emirates (EK)",
  path_geojson: line.([[ams.lng, ams.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 10000, typical_duration_minutes: 750, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. Excellent frequency and rebooking options, but the AMS–DXB leg crosses the active advisory zone.",
  ranking_context: "Ranked below Istanbul because of the advisory zone transit. Emirates' frequency is the strongest contingency option if Istanbul is unavailable.",
  watch_for: "Monitor Gulf advisory zone status. Emirates provides 4+ daily AMS–DXB departures — best rebooking depth on this pair.",
  explanation_bullets: [
    "AMS–DXB transits the active Middle East advisory zone — real exposure on the first leg.",
    "Emirates' high AMS frequency makes this the best recovery option if the Istanbul routing is disrupted.",
    "DXB–BKK is a clean segment with no active advisory concerns.",
    "Journey roughly 45–60 minutes longer than the Istanbul option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: bkk.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR)",
  path_geojson: line.([[ams.lng, ams.lat], [c["Doha"].lng, c["Doha"].lat], [bkk.lng, bkk.lat]]),
  distance_km: 9800, typical_duration_minutes: 740, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Equivalent to the Dubai option; choose based on QR schedule or loyalty preference.",
  ranking_context: "Equal to Dubai on all factors. Qatar Airways offers strong AMS–DOH–BKK frequency as a genuine alternative to Emirates on this corridor.",
  watch_for: "AMS–DOH crosses the Middle East advisory zone. Monitor Doha hub operations — QR has strong resilience but DOH is geographically close to the Levant situation.",
  explanation_bullets: [
    "Qatar Airways operates AMS–DOH–BKK with competitive daily frequency.",
    "AMS–DOH first leg crosses the active advisory zone — same exposure as the Dubai option.",
    "DOH–BKK is uncongested; Qatar Airways' Southeast Asia network is strong.",
    "Slightly shorter total distance than AMS–DXB–BKK due to Doha's more easterly position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Bangkok (3 corridor families: IST, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → SINGAPORE
# Three families: Turkey hub · Gulf (Dubai) · Gulf (Doha)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Air France (AF) + Turkish Airlines (TK) / Singapore Airlines (SQ)",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 11100, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for CDG→SIN. Avoids Gulf exposure on both legs. Air France, Turkish Airlines, and Singapore Airlines all serve this pairing.",
  ranking_context: "Top option for CDG→SIN: avoids the advisory zone on both legs and Air France's daily CDG–IST service connects directly into Turkish Airlines' IST–SIN frequency. CDG–IST is one of the shortest first-leg geometries of any European–Istanbul pairing.",
  watch_for: "IST–SIN second leg routes over Iran/Pakistan — level-1 advisory. Monitor Iranian FIR status if tensions with the West escalate.",
  explanation_bullets: [
    "CDG–IST avoids all advisory exposure. IST–SIN routes east via Pakistan/India with peripheral level-1 airspace exposure.",
    "Air France, Turkish Airlines, and Singapore Airlines all connect on this pairing — strongest combined frequency of any option.",
    "Journey is consistently ~13.5 hours. Istanbul hub well clear of the active advisory zone.",
    "Singapore Airlines also operates CDG–SIN direct — worth comparing if eliminating the hub connection is a priority."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Air France (AF) + Emirates (EK) / Singapore Airlines (SQ)",
  path_geojson: line.([[cdg.lng, cdg.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
  distance_km: 11800, typical_duration_minutes: 855, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. High frequency and strong rebooking options, but the CDG–DXB sector crosses the active advisory zone.",
  ranking_context: "Ranked below Istanbul because the Paris–Dubai leg crosses the advisory zone. Emirates provides the best contingency rebooking if Istanbul is unavailable.",
  watch_for: "Monitor Gulf advisory zone status. Emirates provides 4+ daily CDG–DXB departures — best rebooking depth on this pair.",
  explanation_bullets: [
    "CDG–DXB first leg transits the active Middle East advisory zone — the main risk factor on this option.",
    "Emirates' high CDG frequency makes this the strongest contingency if the Istanbul routing is disrupted or full.",
    "DXB–SIN is a well-established, clean segment with no active advisory concerns.",
    "Total journey roughly 45 minutes longer than the Istanbul option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: sin.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR)",
  path_geojson: line.([[cdg.lng, cdg.lat], [c["Doha"].lng, c["Doha"].lat], [sin.lng, sin.lat]]),
  distance_km: 11600, typical_duration_minutes: 845, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Strong alternative to Dubai with equivalent advisory exposure and excellent QR frequency on CDG–DOH–SIN.",
  ranking_context: "Equal to Dubai option on all factors. Qatar Airways has strong CDG–DOH–SIN frequency and is a genuine competitor to Emirates on this corridor.",
  watch_for: "CDG–DOH crosses the same advisory zone as CDG–DXB. Monitor QR operational alerts. DOH–SIN is a clean, frequent segment.",
  explanation_bullets: [
    "Qatar Airways operates CDG–DOH–SIN with competitive daily frequency.",
    "CDG–DOH first leg crosses the active advisory zone — same exposure as the Dubai option.",
    "DOH–SIN is uncongested and well-served by Qatar Airways' extensive Southeast Asia network.",
    "Slightly shorter total distance than CDG–DXB–SIN due to Doha's more direct position on this route."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Singapore (3 corridor families: IST, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → HONG KONG
# Three families: Turkey hub · Gulf (Dubai) · Central Asia (direct)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: hkg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Air France (AF) + Turkish Airlines (TK) / Cathay Pacific (CX)",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [hkg.lng, hkg.lat]]),
  distance_km: 9500, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for CDG→HKG. Avoids Gulf exposure; the IST–HKG second leg uses the Central Asian corridor but the hub break gives more routing flexibility than going direct.",
  ranking_context: "Top option on pressure (avoids the advisory zone). Ranked above Dubai because the CDG–IST leg has no airspace exposure. Main limitation is the IST–HKG leg's Central Asian corridor dependency.",
  watch_for: "IST–HKG uses the Central Asian corridor — check Eurocontrol ATFM status before the second leg. Delays of 30–60 minutes are common during peak flow restriction periods.",
  explanation_bullets: [
    "CDG–IST is clean. IST–HKG then uses the Central Asian corridor — the congestion bottleneck, but the hub break allows rerouting if needed.",
    "The hub break at Istanbul creates a decision point: you can reassess onward routing if conditions change before the second leg.",
    "Corridor dependency on IST–HKG rated 2/3 — limited alternatives, but better than sole-corridor direct routing.",
    "Air France and Turkish Airlines connect well; Cathay Pacific also serves IST–HKG."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: hkg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Air France (AF) + Emirates (EK) / Cathay Pacific (CX)",
  path_geojson: line.([[cdg.lng, cdg.lat], [dxb.lng, dxb.lat], [hkg.lng, hkg.lat]]),
  distance_km: 11100, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Avoids Central Asian corridor but trades it for Middle East advisory exposure and a longer journey. Best used when Central Asian flow restrictions are active.",
  ranking_context: "Ranked below Istanbul: the Paris–Dubai leg crosses the advisory zone, and DXB–HKG is a longer routing that adds ~2 hours. Best kept as a contingency option.",
  watch_for: "Use this proactively when Eurocontrol issues Central Asian flow restrictions. Monitor Emirates disruption alerts for Gulf escalation.",
  explanation_bullets: [
    "CDG–DXB transits the active advisory zone on the first leg — the main risk factor.",
    "DXB–HKG routes northeast, adding roughly 2 hours versus the Istanbul option.",
    "The structural advantage is avoiding the Central Asian bottleneck entirely on the second leg.",
    "Emirates provides high CDG frequency — strong rebooking depth on the first leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asian Corridor (Direct)",
  carrier_notes: "Air France (AF) direct · Cathay Pacific (CX) direct",
  path_geojson: line.([[cdg.lng, cdg.lat], [55.0, 48.0], [85.0, 45.0], [hkg.lng, hkg.lat]]),
  distance_km: 9400, typical_duration_minutes: 700, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Fastest when the corridor is clear, but the entire route goes through one corridor with no backup. High variance — fastest on a good day, most delayed on a bad one.",
  ranking_context: "The overall score is acceptable, but the route is structurally the most vulnerable: sole-corridor dependency with no alternative path. Airspace is clear — the risk is entirely congestion and flow restrictions.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before every departure. Air France and Cathay both operate direct CDG–HKG but frequency has been reduced since 2022.",
  explanation_bullets: [
    "The entire CDG–HKG route goes through the Central Asian corridor — no practical alternative exists if it's restricted.",
    "Air France and Cathay Pacific both operate direct CDG–HKG, giving some carrier choice but still the same corridor dependency.",
    "On days without ATFM restrictions, this is the fastest option. On days with restrictions, it incurs the longest delays.",
    "Frequency has been reduced by both carriers since 2022 due to rerouting economics — verify current schedules before booking."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Hong Kong (3 corridor families: IST, DXB, central_asia)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → MUMBAI
# Three families: Turkey hub · Gulf (Dubai) · Direct
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: bom.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [bom.lng, bom.lat]]),
  distance_km: 8200, typical_duration_minutes: 625, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best balance for FRA→BOM. Avoids the Middle East advisory zone on both legs; Istanbul is more geographically direct to Mumbai than Dubai.",
  ranking_context: "Top option here: avoids advisory zone exposure and Istanbul is geographically well-placed between Frankfurt and Mumbai. Better structural balance than the direct option despite having a hub stop.",
  watch_for: "IST–BOM second leg routes over Iran — level-1 peripheral advisory. Turkish Airlines has strong IST–BOM frequency with Air India connections.",
  explanation_bullets: [
    "FRA–IST avoids advisory exposure entirely. IST–BOM routes south via Iran — level-1 peripheral advisory, not active routing restriction.",
    "Turkish Airlines and Air India both serve IST–BOM with good frequency; Lufthansa feeds from FRA.",
    "Istanbul is well-positioned between Frankfurt and Mumbai — less geographic deviation than the Dubai routing.",
    "Journey is ~10.5 hours — efficient one-stop for this pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: bom.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) / Air India (AI)",
  path_geojson: line.([[fra.lng, fra.lat], [dxb.lng, dxb.lat], [bom.lng, bom.lat]]),
  distance_km: 8900, typical_duration_minutes: 675, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. High frequency and rebooking depth, but the FRA–DXB leg crosses the active advisory zone. Use as backup when Istanbul is unavailable.",
  ranking_context: "Ranked below Istanbul because the Frankfurt–Dubai leg crosses the advisory zone. Emirates provides the highest rebooking flexibility if the Istanbul routing is disrupted.",
  watch_for: "Monitor Gulf advisory zone escalation. Emirates has strong FRA–DXB frequency. DXB–BOM is a clean, frequent segment.",
  explanation_bullets: [
    "FRA–DXB first leg transits the active Middle East advisory zone.",
    "Emirates provides the best first-leg rebooking depth of any option on this pair.",
    "DXB–BOM is a very short, clean segment — no advisory concerns.",
    "Journey roughly 45 minutes longer than Istanbul option due to more southerly geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Lufthansa Direct",
  carrier_notes: "Lufthansa (LH) direct · Air India (AI) direct",
  path_geojson: line.([[fra.lng, fra.lat], [35.0, 32.0], [bom.lng, bom.lat]]),
  distance_km: 7200, typical_duration_minutes: 560, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Shortest journey — no connection, no hub risk. The trade-off is that the direct route crosses the Middle East advisory zone, and carrier options are limited to Lufthansa and Air India.",
  ranking_context: "Best structural score (no hub) but highest airspace pressure of the three: the entire ~9-hour direct flight transits the advisory zone. If disrupted, rebooking to an alternative non-stop is limited.",
  watch_for: "The entire direct route crosses the Middle East advisory zone. Monitor advisory escalation. Lufthansa and Air India are the only direct carriers — rebooking to a connection may be necessary if disrupted.",
  explanation_bullets: [
    "No hub, no connection — structurally the simplest journey with the lowest miss-connection risk.",
    "The direct FRA–BOM route transits the Middle East advisory zone for roughly 5 hours of the flight.",
    "Only Lufthansa and Air India operate this non-stop route — limited rebooking options if the flight is cancelled or severely delayed.",
    "Fastest option by elapsed time: ~9.5 hours versus ~10.5 hours via Istanbul."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Mumbai (3 corridor families: IST, DXB, direct)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → TOKYO
# Four families: central_asia direct · Turkey hub · North Asia HKG · North Asia ICN
# Seoul wins here because ICN hub_score=0 vs IST hub_score=1, and ICN→NRT is 2h
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Lufthansa Direct (Central Asian Routing)",
  carrier_notes: "Lufthansa (LH) direct — rerouted via Central Asian corridor since 2022",
  path_geojson: line.([[fra.lng, fra.lat], [50.0, 46.0], [82.0, 46.0], [nrt.lng, nrt.lat]]),
  distance_km: 11800, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Fastest total journey when the corridor is clear, but the entire flight depends on the Central Asian corridor — no viable alternative if it's restricted on departure day.",
  ranking_context: "Sole-corridor dependency (3/3) is the defining structural risk. On a clear day it's the fastest option. On a restriction day it's the most delayed, with no reroute option. Treat it as high-variance, not a safe default.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before every departure. Lufthansa has reduced FRA–NRT frequency since 2022 — verify current schedule.",
  explanation_bullets: [
    "Corridor dependency rated 3/3: the entire FRA–NRT route goes through the Central Asian corridor with no alternative path.",
    "Lufthansa flies direct but frequency is reduced post-2022 due to rerouting economics. Rebooking onto other direct flights is limited.",
    "No hub means no missed connection risk — but also no natural reroute point if the corridor is restricted. You restart from Frankfurt.",
    "Pre-2022 FRA–NRT was ~12 hours via Russia. Current routing via Central Asia runs 14.5–15.5 hours depending on ATFM delays."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: nrt.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) / Japan Airlines (JL)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [55.0, 40.0], [90.0, 40.0], [nrt.lng, nrt.lat]]),
  distance_km: 12400, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Better structural resilience than the direct flight — the hub break at Istanbul creates a decision point. IST–NRT still uses the Central Asian corridor but you're not committed to it on a single ticket.",
  ranking_context: "Ranks above the direct (65 vs 58) because the hub break reduces corridor fragility: if conditions deteriorate before Istanbul, you can reassess onward routing. Ranks below Seoul (65 vs 70) because IST hub score is 1 vs ICN hub score 0.",
  watch_for: "IST–NRT traverses the Central Asian corridor — same exposure point as the direct flight, but you have a natural decision checkpoint at Istanbul.",
  explanation_bullets: [
    "The hub break at Istanbul creates structural optionality: you can assess Central Asian corridor conditions before committing to the second leg.",
    "Corridor dependency 2/3 (not 3/3 like direct) reflects that the IST hub creates a real decision point and alternative routing options.",
    "Lufthansa, Turkish Airlines, and Japan Airlines all operate on this pairing — good combined frequency and rebooking depth.",
    "IST hub carries level-1 risk score — regional proximity warrants monitoring but has not affected operations.",
    "Journey is approximately 1.5 hours longer than a clear-day direct flight; schedule variance is lower."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: nrt.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Lufthansa (LH) + Korean Air (KE) / ANA (NH) / Japan Airlines (JL)",
  path_geojson: line.([[fra.lng, fra.lat], [60.0, 44.0], [icn.lng, icn.lat], [nrt.lng, nrt.lat]]),
  distance_km: 10400, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best-rated option for FRA→NRT. Avoids Gulf entirely; ICN is a world-class hub with excellent onward frequency to Tokyo. The ICN→NRT second leg is only 2 hours — dramatically shorter than IST→NRT.",
  ranking_context: "Ranks highest here (70) because ICN hub scores 0 vs IST's 1, and the short ICN→NRT second leg (2h, no corridor exposure) gives this routing a structural edge. The FRA→ICN first leg uses Central Asian corridor — same as the direct flight — but the hub break and short final leg materially reduce risk.",
  watch_for: "FRA→ICN uses the Central Asian corridor — same exposure as the direct flight on the first leg. Check ATFM status before departure. ICN→NRT transits Korean/Japanese airspace: clean, uncongested, no advisories.",
  explanation_bullets: [
    "ICN hub scores 0/3 (world-class) — the structural advantage over Istanbul, which scores 1/3 due to regional proximity to tensions.",
    "The ICN→NRT second leg is only ~2 hours via clean Korean/Japanese airspace — dramatically shorter and less exposed than IST→NRT (9 hours through Central Asian corridor).",
    "FRA→ICN first leg uses the Central Asian corridor. This is the same structural constraint as the direct flight, but the hub break at Seoul gives recovery optionality.",
    "Korean Air, ANA, and Japan Airlines all serve ICN→NRT with very high frequency — the best second-leg rebooking depth of any option here.",
    "Total journey with a normal layover runs ~14.5 hours. On a clear day the direct flight is faster; via Seoul is more resilient."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong (Cathay South Routing)",
  carrier_notes: "Cathay Pacific (CX) — routes FRA–HKG via South Asia corridor, avoiding Central Asian congestion",
  path_geojson: line.([[fra.lng, fra.lat], [45.0, 28.0], [80.0, 20.0], [hkg.lng, hkg.lat], [nrt.lng, nrt.lat]]),
  distance_km: 14100, typical_duration_minutes: 990, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Best structural resilience — Cathay avoids Central Asian corridor entirely on the FRA–HKG leg. The trade-off: Middle East advisory zone transit on the first leg and the longest total distance of the four options.",
  ranking_context: "Lowest ranking (63) because the south routing adds both airspace exposure (advisory zone on first leg) and significant distance. Choose this when Central Asian corridor restrictions are confirmed active and you want a corridor with genuine alternative paths.",
  watch_for: "Cathay Pacific may route-select FRA–HKG north via Central Asia depending on conditions. Confirm the south routing before booking if corridor avoidance is the reason you're choosing this option. HKG–NRT is a clean northeast Asian segment.",
  explanation_bullets: [
    "Cathay's south routing for FRA–HKG bypasses the Central Asian congestion bottleneck entirely — the primary structural advantage over the other three options.",
    "Corridor dependency rated 1/3: the south Asian routing (Arabian Sea / Bay of Bengal) has genuine alternative sub-paths, unlike the Central Asian sole-corridor.",
    "The FRA–HKG leg transits the Middle East advisory zone — the trade-off for avoiding Central Asian congestion.",
    "HKG–NRT approaches Tokyo from the south-southwest. The segment is clean and uncongested; HKG hub is world-class.",
    "Total journey is the longest of the four options (~16.5 hours). Choose this only when Central Asian corridor avoidance is the explicit priority."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: nrt.id, via_hub_city_id: pek.id,
  corridor_family: "china_arc",
  route_name: "Via Beijing",
  carrier_notes: "Air China (CA) · daily FRA–PEK–NRT",
  path_geojson: line.([[fra.lng, fra.lat], [50.0, 46.0], [85.0, 44.0], [pek.lng, pek.lat], [nrt.lng, nrt.lat]]),
  distance_km: 9900, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Air China's China-side option for FRA→NRT. PEK→NRT is a short, clean segment (~3 hours) over Yellow Sea airspace with no active advisories. The FRA→PEK first leg uses the Central Asian corridor — same structural dependency as Via Istanbul and Via Seoul.",
  ranking_context: "Ranks similarly to Istanbul because both use the Central Asian corridor on the first leg and both hubs carry a 1/3 hub risk. The PEK→NRT second leg (~3 hours) is shorter than IST→NRT (~9 hours via Central Asia) — a structural edge — but the PRC hub context offsets this. Via Seoul remains the strongest option (hub_score 0 vs 1).",
  watch_for: "FRA→PEK uses the Central Asian corridor — check Eurocontrol ATFM status before departure. Monitor Air China FRA–PEK bilateral route access; PRC aviation policy changes can affect service frequency on short notice.",
  explanation_bullets: [
    "Air China operates daily FRA→PEK direct service, connecting to multiple daily PEK→NRT frequencies — this is a real, high-frequency corridor option.",
    "PEK→NRT is only ~3 hours over clean Yellow Sea/East China Sea airspace with no active airspace advisories.",
    "FRA→PEK first leg uses Central Asian corridor — the same routing constraint as Via Istanbul and Via Seoul on this pair.",
    "Beijing hub rated 1/3: major hub with strong operational resilience, but PRC political and regulatory context means bilateral route access warrants monitoring.",
    "Total journey runs approximately 14 hours — comparable to Via Istanbul. The China-side routing may suit travellers with Air China status, flexible fares, or a Beijing stopover."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Tokyo (5 corridor families: central_asia, IST, ICN, HKG, beijing/china_arc) — Seoul ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → BANGKOK
# Three families: Turkey hub · Gulf (Dubai) · Gulf (Doha)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Air France (AF) + Turkish Airlines (TK)",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9100, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for CDG→BKK. Avoids the Middle East advisory zone on both legs; Istanbul is geographically well-placed between Paris and Bangkok.",
  ranking_context: "Top option for CDG→BKK: avoids the advisory zone and Istanbul sits nearly on the great-circle line between Paris and Bangkok — minimal routing deviation versus a Gulf stop. CDG–IST is under 4 hours, keeping total journey time competitive.",
  watch_for: "IST–BKK routes east via Iran/Pakistan. Level-1 peripheral advisory. Turkish Airlines has 4+ daily IST–BKK departures; strong rebooking depth on the second leg.",
  explanation_bullets: [
    "CDG–IST uses standard western European routing — no advisory exposure. IST–BKK routes east with level-1 peripheral exposure only.",
    "Air France feeds into IST with multiple daily departures; Turkish Airlines' IST–BKK service has strong frequency.",
    "Istanbul hub is geographically efficient between Paris and Bangkok — less deviation than a Gulf routing.",
    "Journey consistently ~11.5 hours under current airspace conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Air France (AF) + Emirates (EK)",
  path_geojson: line.([[cdg.lng, cdg.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9700, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. Excellent frequency and rebooking options, but the CDG–DXB first leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranks below Istanbul because the Paris–Dubai leg crosses the advisory zone. Emirates provides the strongest contingency rebooking if Istanbul is disrupted or sold out.",
  watch_for: "Monitor Middle East advisory zone status. Emirates has 4+ daily CDG–DXB departures — best rebooking depth on this pair if disruption forces a change.",
  explanation_bullets: [
    "CDG–DXB first leg transits the active Middle East advisory zone — real exposure on the first 7-hour segment.",
    "Emirates' high CDG frequency makes this the best contingency option if Istanbul is unavailable.",
    "DXB–BKK is a clean, well-established segment with no active advisory concerns.",
    "Total journey roughly 45–50 minutes longer than Istanbul due to more southerly geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: bkk.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR)",
  path_geojson: line.([[cdg.lng, cdg.lat], [c["Doha"].lng, c["Doha"].lat], [bkk.lng, bkk.lat]]),
  distance_km: 9500, typical_duration_minutes: 715, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Equivalent pressure and structure to the Dubai option; choose based on QR schedule or alliance preference.",
  ranking_context: "Scores equal to Dubai on all factors. Qatar Airways offers genuine competition on CDG–DOH–BKK frequency and is a real alternative to Emirates on this corridor.",
  watch_for: "CDG–DOH crosses the same advisory zone as CDG–DXB. Doha hub sits closer to the Levant situation than Dubai — monitor QR operational alerts if regional tensions escalate.",
  explanation_bullets: [
    "Qatar Airways operates CDG–DOH–BKK with competitive daily frequency — a genuine alternative to Emirates, not just a fallback.",
    "CDG–DOH first leg crosses the Middle East advisory zone, same exposure as the Dubai option.",
    "DOH–BKK is uncongested; Qatar Airways' Southeast Asia network is strong.",
    "Slightly shorter total distance than CDG–DXB–BKK due to Doha's more easterly position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Bangkok (3 corridor families: IST, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → HONG KONG
# Three families: Turkey hub · Gulf (Dubai) · Central Asia (direct)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: hkg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK) / Cathay Pacific (CX)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [hkg.lng, hkg.lat]]),
  distance_km: 9400, typical_duration_minutes: 710, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for AMS→HKG. Avoids Gulf exposure; the IST–HKG second leg uses the Central Asian corridor, but the hub break provides routing flexibility.",
  ranking_context: "Top option on pressure (avoids advisory zone). Corridor dependency on IST–HKG (2/3) is the main structural risk — the Central Asian bottleneck — but the hub break allows rerouting if needed.",
  watch_for: "IST–HKG uses the Central Asian corridor. Check Eurocontrol ATFM status before the second leg. Delays of 30–60 minutes are common during peak restriction periods.",
  explanation_bullets: [
    "AMS–IST uses standard north European routing — no advisory exposure. IST–HKG then traverses the Central Asian corridor.",
    "The hub break at Istanbul creates a decision point: conditions can be assessed before committing to the longer second leg.",
    "KLM and Turkish Airlines both operate AMS–IST with good frequency; Cathay Pacific connects IST–HKG.",
    "Corridor dependency rated 2/3 — limited alternatives on the IST–HKG segment, but better than sole-corridor direct routing."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: hkg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "KLM (KL) + Emirates (EK) / Cathay Pacific (CX)",
  path_geojson: line.([[ams.lng, ams.lat], [dxb.lng, dxb.lat], [hkg.lng, hkg.lat]]),
  distance_km: 11000, typical_duration_minutes: 805, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Avoids Central Asian corridor but trades it for Middle East advisory zone exposure and ~2 extra hours. Best used when Central Asian flow restrictions are confirmed active.",
  ranking_context: "Ranks below Istanbul (57 vs 65) because both the advisory zone transit and routing complexity are elevated. The structural value is avoiding the Central Asian bottleneck on the AMS–DXB–HKG routing.",
  watch_for: "Use proactively when Eurocontrol issues Central Asian flow restrictions affecting the Istanbul routing. The AMS–DXB leg carries advisory zone exposure in exchange for Central Asian avoidance.",
  explanation_bullets: [
    "Bypasses Central Asian corridor entirely — the structural advantage when that bottleneck is under flow restriction.",
    "AMS–DXB first leg transits the Middle East advisory zone: this is the direct trade-off for avoiding Central Asian congestion.",
    "DXB–HKG routes northeast, adding roughly 2 hours versus the Istanbul option.",
    "Emirates provides strong AMS–DXB rebooking frequency — best contingency option if the Istanbul routing is unavailable."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "KLM Direct (Central Asian Routing)",
  carrier_notes: "KLM (KL) direct · Cathay Pacific (CX) direct via Central Asian corridor",
  path_geojson: line.([[ams.lng, ams.lat], [52.0, 47.0], [82.0, 44.0], [hkg.lng, hkg.lat]]),
  distance_km: 9200, typical_duration_minutes: 685, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Fastest when the corridor is clear. No hub connection risk. But the entire flight depends on the Central Asian corridor — high variance, no alternative if restricted.",
  ranking_context: "Sole-corridor dependency (3/3) is the defining structural risk — the same fragility as the Paris and Frankfurt direct-to-HKG options. Fastest on a good day; most delayed on a restriction day.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before every departure. KLM and Cathay both operate direct AMS–HKG, but frequency has been reduced since 2022.",
  explanation_bullets: [
    "The entire AMS–HKG route goes through the Central Asian corridor — corridor dependency 3/3, no viable alternative if restricted.",
    "No hub means no missed connection risk. But disruption means restarting from Amsterdam with no reroute option.",
    "KLM and Cathay Pacific both operate direct AMS–HKG. Some carrier choice, but the same corridor constraint on both.",
    "Fastest option by elapsed time when operating normally. High delay variance on restriction days."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Hong Kong (3 corridor families: IST, DXB, central_asia)")

# ─────────────────────────────────────────────────────────────────────────────
# JAKARTA → AMSTERDAM
# Four families: south_asia_direct (SIN) · North Asia (HKG) · Gulf (Dubai) · Gulf (Doha)
# Via Singapore is the natural winner — shortest total distance, no Gulf exposure.
# Via Hong Kong avoids Gulf entirely via Central Asian routing on second leg.
# Gulf hubs score lower: the DXB/DOH→AMS second leg crosses the advisory zone.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: ams.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) — CGK–SIN then SQ's direct SIN–AMS service",
  path_geojson: line.([[cgk.lng, cgk.lat], [sin.lng, sin.lat], [75.0, 20.0], [45.0, 35.0], [ams.lng, ams.lat]]),
  distance_km: 11700, typical_duration_minutes: 940, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best overall for CGK→AMS. Singapore is a natural waypoint on this route. Singapore Airlines' direct SIN–AMS service keeps both legs clean of Gulf advisory exposure.",
  ranking_context: "Ranks first: shortest total distance, world-class SIN hub, and the SIN–AMS leg routes via South Asia/Central Asia rather than through the Gulf advisory zone. Peripheral airspace exposure on the second leg rather than a direct advisory zone transit.",
  watch_for: "SIN–AMS routes over South Asia. India-Pakistan regional tensions have periodically created short-notice airspace restrictions on this corridor. Singapore Airlines has strong rerouting protocols, but verify SQ alerts within 48 hours of departure.",
  explanation_bullets: [
    "Singapore lies almost directly on the great-circle path from Jakarta to Amsterdam — minimal geometric detour versus a true non-stop.",
    "SIN hub scores 0/3 (world-class): one of the most resilient transit hubs on the Europe–Asia corridor.",
    "Singapore Airlines operates SIN–AMS direct. Both legs avoid the core Middle East advisory zone — the CGK–SIN segment is entirely within clean Southeast Asian airspace.",
    "The SIN–AMS second leg routes via South Asian airspace, which carries a level-1 advisory (peripheral) — not the active zone transit that Gulf hubs incur.",
    "Singapore Airlines has strong frequency and rebooking options on both CGK–SIN and SIN–AMS."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: ams.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) — CGK–HKG then CX direct HKG–AMS via Central Asian routing",
  path_geojson: line.([[cgk.lng, cgk.lat], [hkg.lng, hkg.lat], [80.0, 42.0], [45.0, 46.0], [ams.lng, ams.lat]]),
  distance_km: 12800, typical_duration_minutes: 960, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "No Gulf exposure on either leg. Cathay's HKG–AMS routing goes north over Central Asia, completely clear of the Middle East advisory zone. Best option if Gulf airspace risk is your primary concern.",
  ranking_context: "Ranks second (78 vs 81 via Singapore): slightly longer total distance because Hong Kong is northeast of Jakarta and requires a modest backtrack. Both options have equivalent airspace pressure (level-1 peripheral). The difference is geography, not airspace.",
  watch_for: "HKG–AMS uses the Central Asian corridor. Check Eurocontrol ATFM status before departure — flow restrictions are issued multiple times per week during peak periods and can add 30–60 minutes.",
  explanation_bullets: [
    "HKG–AMS routes north via Central Asia, passing well above the Middle East advisory zone — both legs of this journey avoid Gulf airspace entirely.",
    "HKG hub scores 0/3: Cathay Pacific maintains a world-class operation with strong resilience through the post-2022 disruption period.",
    "CGK–HKG is a short, clean first leg (~5 hours) via the South China Sea — no advisory concerns.",
    "The Central Asian corridor carries level-1 peripheral advisory status due to congestion, not an active conflict zone. Delays are possible; route closures are not.",
    "Cathay Pacific operates direct HKG–AMS with solid frequency. Comparable carrier depth to the Singapore option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) — CGK–DXB–AMS, daily service",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [35.0, 38.0], [ams.lng, ams.lat]]),
  distance_km: 11600, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High frequency and the strongest rebooking options of any CGK→AMS option. Emirates operates this daily. The trade-off: the DXB→AMS second leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranks below the Asian hub options (58 vs 78–81) because the DXB–AMS leg explicitly crosses the active advisory zone — the same exposure that lowers Gulf hub scores across all Europe-Asia pairs. Emirates' frequency is the contingency advantage.",
  watch_for: "DXB–AMS transits the active Middle East advisory zone. EASA warnings are in effect. Emirates has maintained service without suspension, but Levant or Iranian escalation could affect this routing with limited warning.",
  explanation_bullets: [
    "The DXB–AMS second leg crosses the active Middle East advisory zone — this is the route's primary risk factor and should be weighed explicitly against the frequency advantage.",
    "Emirates operates daily CGK–DXB–AMS service with strong rebooking depth. If disruption occurs on either leg, Emirates' network has the most recovery options.",
    "CGK–DXB first leg routes via the Indian Ocean and Arabian Sea — the Gulf approach carries some advisory proximity, but the primary advisory exposure is on the second leg.",
    "Dubai hub has operated without closure or significant restriction throughout the current conflict period.",
    "EASA and UK CAA have issued active warnings for portions of this corridor. Conditions can escalate rapidly."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: ams.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) — CGK–DOH–AMS",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [c["Doha"].lng, c["Doha"].lat], [35.0, 38.0], [ams.lng, ams.lat]]),
  distance_km: 11600, typical_duration_minutes: 910, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Equivalent advisory exposure to the Dubai option — DOH–AMS also crosses the active advisory zone. Choose based on QR availability or schedule preference.",
  ranking_context: "Scores identically to the Dubai option on all factors (58, Watchful). DOH hub sits closer to the Levant situation than DXB; the risk profiles are effectively the same. The deciding factor is airline preference or schedule fit.",
  watch_for: "DOH–AMS transits the active Middle East advisory zone on the second leg. Doha is geographically closer to the Levant situation than Dubai — monitor Qatar Airways operational alerts if regional tensions escalate further.",
  explanation_bullets: [
    "DOH–AMS second leg crosses the active advisory zone — the same core risk factor as the Dubai option.",
    "Qatar Airways operates CGK–DOH–AMS with competitive frequency and a world-class DOH hub.",
    "Doha sits slightly closer to the Levant conflict zone than Dubai, but both Gulf hubs have operated without suspension throughout the current period.",
    "QR's Southeast Asia and European networks are both strong — rebooking options at DOH are good if either leg is disrupted.",
    "Slightly shorter than the Dubai routing due to Doha's more easterly position, but the difference is minimal."
  ],
  calculated_at: now
})

IO.puts("  ✓ Jakarta → Amsterdam (4 corridor families: SIN, HKG, DXB, DOH) — Via Singapore ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# JAKARTA → LONDON
# Four families: south_asia_direct (SIN) · North Asia (HKG) · Gulf (Dubai) · Gulf (Doha)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: lhr.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) — CGK–SIN–LHR",
  path_geojson: line.([[cgk.lng, cgk.lat], [sin.lng, sin.lat], [75.0, 22.0], [40.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 11850, typical_duration_minutes: 950, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best overall for CGK→LHR. Singapore is the natural midpoint. SQ's direct SIN–LHR service keeps both legs clear of the Gulf advisory zone.",
  ranking_context: "Ranks first: SIN hub is world-class, the geometry is nearly optimal, and neither leg transits the Middle East advisory zone. SIN–LHR routes via South/Central Asia with only level-1 peripheral exposure.",
  watch_for: "SIN–LHR routes via South Asian airspace. India-Pakistan tensions can create short-notice restrictions. Singapore Airlines reroutes proactively — check SQ alerts 48h before departure.",
  explanation_bullets: [
    "Singapore sits naturally on the CGK–LHR great-circle path — less geographic detour than Gulf or East Asian hubs.",
    "SIN hub scores 0/3: no regional conflict proximity, excellent resilience throughout the post-2022 disruption period.",
    "Neither leg crosses the Middle East advisory zone. SIN–LHR routes northeast via South Asian airspace (level-1 peripheral advisory)."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: lhr.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) — CGK–HKG–LHR via Central Asian routing",
  path_geojson: line.([[cgk.lng, cgk.lat], [hkg.lng, hkg.lat], [80.0, 44.0], [40.0, 48.0], [lhr.lng, lhr.lat]]),
  distance_km: 12900, typical_duration_minutes: 970, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Gulf-free alternative via Cathay's HKG hub. HKG–LHR routes north over Central Asia — both legs avoid the advisory zone. Best if your priority is minimising Gulf exposure.",
  ranking_context: "Ranks second (78 vs 81 via Singapore). The backtrack from Jakarta northeast to Hong Kong then west to London adds ~1,100km. Airspace exposure is equivalent: both options carry level-1 peripheral advisory.",
  watch_for: "HKG–LHR uses the Central Asian corridor. Check Eurocontrol ATFM status before departure — delays of 30–60 minutes are common during peak restriction periods.",
  explanation_bullets: [
    "HKG–LHR routing goes north via Central Asian airspace, cleanly above the Middle East advisory zone.",
    "Cathay Pacific's HKG hub is world-class and has maintained full LHR service throughout the post-2022 period.",
    "The CGK–HKG first leg is short and clean (~5h via South China Sea)."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) — CGK–DXB–LHR, daily",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [30.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 11600, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Highest rebooking depth via Emirates. DXB–LHR crosses the active Middle East advisory zone — use when Asian hub options are unavailable or disrupted.",
  ranking_context: "Scores below the Asian hub options (58 vs 78–81) because DXB–LHR transits the active advisory zone. Emirates' frequency gives the best contingency options on this pair.",
  watch_for: "DXB–LHR transits the active Middle East advisory zone. EASA warnings remain in effect. Emirates has maintained service, but regional escalation could affect this routing with limited warning.",
  explanation_bullets: [
    "DXB–LHR second leg crosses the active advisory zone — the defining risk factor for this option.",
    "Emirates operates daily CGK–DXB–LHR with strong rebooking depth at both ends.",
    "CGK–DXB is a clean first leg via the Indian Ocean, clear of the advisory zone."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: lhr.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) — CGK–DOH–LHR",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [c["Doha"].lng, c["Doha"].lat], [30.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 11500, typical_duration_minutes: 905, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Same advisory exposure as the Dubai option — DOH–LHR also crosses the active zone. Choose based on QR schedule or loyalty preference.",
  ranking_context: "Scores identically to the Dubai option. DOH hub sits slightly closer to the Levant situation than DXB; risk profiles are effectively equal. Choose on airline fit.",
  watch_for: "DOH–LHR transits the active Middle East advisory zone. Doha is geographically close to the Levant situation — monitor QR alerts if tensions escalate.",
  explanation_bullets: [
    "DOH–LHR second leg crosses the active advisory zone — same exposure as the Dubai option.",
    "Qatar Airways operates CGK–DOH–LHR with competitive frequency and strong DOH rebooking depth.",
    "Slightly shorter total distance than via DXB due to Doha's more direct position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Jakarta → London (4 corridor families: SIN, HKG, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# JAKARTA → PARIS
# Four families: south_asia_direct (SIN) · North Asia (HKG) · Gulf (Dubai) · Gulf (Doha)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: cdg.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) — CGK–SIN–CDG",
  path_geojson: line.([[cgk.lng, cgk.lat], [sin.lng, sin.lat], [70.0, 22.0], [35.0, 42.0], [cdg.lng, cdg.lat]]),
  distance_km: 11900, typical_duration_minutes: 955, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best overall for CGK→CDG. Singapore is the natural midpoint; SQ's SIN–CDG service keeps both legs outside the Gulf advisory zone.",
  ranking_context: "Same profile as CGK→LHR via Singapore: world-class SIN hub, optimal geometry, both legs avoid the advisory zone. First choice for risk-aware travelers.",
  watch_for: "SIN–CDG routes via South Asian airspace. India-Pakistan tensions can create short-notice restrictions. Singapore Airlines reroutes proactively.",
  explanation_bullets: [
    "Singapore lies near-optimally on the great-circle path — minimal detour versus a direct flight.",
    "SIN hub scores 0/3: no regional conflict proximity, excellent operational resilience.",
    "Neither leg crosses the Middle East advisory zone — the core advantage over Gulf hub options."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: cdg.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) — CGK–HKG–CDG via Central Asian routing",
  path_geojson: line.([[cgk.lng, cgk.lat], [hkg.lng, hkg.lat], [78.0, 44.0], [35.0, 47.0], [cdg.lng, cdg.lat]]),
  distance_km: 12950, typical_duration_minutes: 975, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Gulf-free alternative. Cathay's HKG–CDG service routes north via Central Asia, avoiding the advisory zone on both legs.",
  ranking_context: "Ranks second (78 vs 81 via Singapore). Hong Kong requires a northeast backtrack from Jakarta; airspace pressure is equivalent. The difference is geometry.",
  watch_for: "HKG–CDG uses the Central Asian corridor. Check Eurocontrol ATFM status before departure.",
  explanation_bullets: [
    "HKG–CDG routing goes north over Central Asia, well clear of the Middle East advisory zone.",
    "Cathay Pacific's HKG hub is world-class with strong European connectivity.",
    "CGK–HKG first leg is short (~5h) with no advisory concerns."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) — CGK–DXB–CDG, daily",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [25.0, 40.0], [cdg.lng, cdg.lat]]),
  distance_km: 11700, typical_duration_minutes: 905, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Highest rebooking depth via Emirates. DXB–CDG crosses the active advisory zone — use when Asian hub options are full or disrupted.",
  ranking_context: "Scores 58 vs 78–81 for Asian hub options because the DXB–CDG leg transits the active advisory zone. Emirates' frequency is the contingency value.",
  watch_for: "DXB–CDG transits the active Middle East advisory zone. EASA warnings remain active for portions of this corridor.",
  explanation_bullets: [
    "DXB–CDG second leg crosses the active advisory zone — the defining risk factor.",
    "Emirates offers daily CGK–DXB–CDG with strong frequency and rebooking depth.",
    "CGK–DXB first leg routes via the Indian Ocean, clear of the advisory zone."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: cdg.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) — CGK–DOH–CDG",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [c["Doha"].lng, c["Doha"].lat], [25.0, 40.0], [cdg.lng, cdg.lat]]),
  distance_km: 11600, typical_duration_minutes: 910, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways alternative via Doha. Same advisory exposure as Dubai — DOH–CDG crosses the active zone. Choose on QR schedule preference.",
  ranking_context: "Scores identically to the Dubai option (58). DOH is slightly closer to the Levant situation; risk profiles are effectively equal.",
  watch_for: "DOH–CDG transits the active Middle East advisory zone. Monitor QR operational alerts if regional tensions escalate.",
  explanation_bullets: [
    "DOH–CDG second leg crosses the active advisory zone — same exposure as the Dubai option.",
    "Qatar Airways operates CGK–DOH–CDG with competitive frequency and world-class DOH hub.",
    "Slightly shorter total distance than via DXB due to Doha's more direct position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Jakarta → Paris (4 corridor families: SIN, HKG, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → DELHI
# Three families: Turkey hub · Direct (Gulf corridor) · Gulf (Dubai)
# Istanbul wins: avoids advisory zone, same as LHR/FRA/CDG→DEL pattern.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: del.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [del.lng, del.lat]]),
  distance_km: 8300, typical_duration_minutes: 635, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best balance for AMS→DEL. Avoids the Middle East advisory zone on both legs; Istanbul hub is geographically efficient between Amsterdam and Delhi.",
  ranking_context: "Top option: avoids the advisory zone and has better pressure score (77) than direct or Gulf options (53). The same argument that applies to LHR→DEL via Istanbul applies here.",
  watch_for: "IST–DEL second leg routes over Iran/Pakistan — level-1 peripheral advisory. Turkish Airlines has good IST–DEL frequency with Air India connections.",
  explanation_bullets: [
    "AMS–IST avoids advisory exposure entirely. IST–DEL routes south via Iran/Pakistan with peripheral level-1 exposure only.",
    "Pressure score advantage (77 vs 53) is the clearest argument for this option over the direct or Dubai routing.",
    "Hub connection introduces missed-connection risk, partly offset by Turkish Airlines' reliable IST hub."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct via Gulf Corridor",
  carrier_notes: "KLM (KL) · Air India (AI)",
  path_geojson: line.([[ams.lng, ams.lat], [45.0, 33.0], [del.lng, del.lat]]),
  distance_km: 6750, typical_duration_minutes: 515, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Fastest option — no connection, no hub. The entire route transits the Middle East advisory zone. Choose when schedule simplicity matters more than airspace exposure.",
  ranking_context: "Structural score is high (85) — direct routing, no hub dependency. Composite capped at 60 because the full sector crosses the active advisory zone.",
  watch_for: "The entire AMS–DEL direct sector transits the Middle East advisory zone for ~4 hours. Monitor UK FCDO and Dutch MFA advisories.",
  explanation_bullets: [
    "No hub, no connection — the simplest journey structure with the lowest missed-flight risk.",
    "The AMS–DEL direct route transits the active advisory zone for approximately 4 hours of the ~9-hour flight.",
    "KLM and Air India operate this route — adequate frequency but narrower rebooking depth than the Istanbul option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: del.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "KLM (KL) + Emirates (EK) / Air India (AI)",
  path_geojson: line.([[ams.lng, ams.lat], [dxb.lng, dxb.lat], [del.lng, del.lat]]),
  distance_km: 8500, typical_duration_minutes: 645, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Highest rebooking depth via Emirates. AMS–DXB crosses the advisory zone — same exposure as the direct flight but with stronger contingency options at the hub.",
  ranking_context: "Scores 60 vs 72 for Istanbul. Advisory zone exposure on the first leg is the differentiator. Emirates' frequency is the main advantage over the direct option.",
  watch_for: "AMS–DXB transits the active Middle East advisory zone. Use this when Istanbul is unavailable; monitor Emirates alerts for Gulf escalation.",
  explanation_bullets: [
    "AMS–DXB first leg transits the active advisory zone — same exposure as flying direct.",
    "Emirates' AMS frequency gives the best first-leg rebooking depth of the three options.",
    "DXB–DEL is a short, clean segment with no advisory concerns."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Delhi (3 corridor families: IST, direct, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → MUMBAI
# Three families: Turkey hub · Direct (Gulf corridor) · Gulf (Dubai)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: bom.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [bom.lng, bom.lat]]),
  distance_km: 8500, typical_duration_minutes: 650, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best balance for AMS→BOM. Avoids the advisory zone on both legs; Istanbul is well-positioned between Amsterdam and Mumbai.",
  ranking_context: "Top option: pressure score 77 vs 53 for direct/Gulf options. Same structural argument as all European→India via Istanbul pairs.",
  watch_for: "IST–BOM routes over Iran — level-1 peripheral advisory. Turkish Airlines operates IST–BOM with Air India connections.",
  explanation_bullets: [
    "AMS–IST avoids advisory exposure. IST–BOM routes south via Iran with only peripheral level-1 exposure.",
    "Pressure score advantage of 24 points (77 vs 53) is the core reason to prefer Istanbul over direct.",
    "Hub dependency introduces missed-connection risk, offset by Turkish Airlines' reliable hub operations."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct via Gulf Corridor",
  carrier_notes: "KLM (KL) · Air India (AI)",
  path_geojson: line.([[ams.lng, ams.lat], [44.0, 30.0], [bom.lng, bom.lat]]),
  distance_km: 7200, typical_duration_minutes: 550, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Fastest option — direct, no connection. The full sector crosses the Middle East advisory zone for roughly 5 hours. Use when simplicity matters more than airspace exposure.",
  ranking_context: "Direct routing gives structural score 85 but composite is capped at 60 due to advisory zone transit. Fastest option; highest airspace exposure.",
  watch_for: "The full AMS–BOM direct route transits the Middle East advisory zone. Monitor Dutch MFA and EASA advisories before departure.",
  explanation_bullets: [
    "No hub, no connection — structurally simple with low missed-flight risk.",
    "The AMS–BOM direct sector crosses the active advisory zone for approximately 5 hours.",
    "KLM and Air India operate this route — adequate frequency, but rebooking to alternatives requires switching to a hub option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: bom.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "KLM (KL) + Emirates (EK) / Air India (AI)",
  path_geojson: line.([[ams.lng, ams.lat], [dxb.lng, dxb.lat], [bom.lng, bom.lat]]),
  distance_km: 9050, typical_duration_minutes: 675, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Emirates via Dubai — most rebooking depth of the three options. AMS–DXB crosses the advisory zone; use as backup when Istanbul is unavailable.",
  ranking_context: "Scores 60 vs 72 for Istanbul. Same advisory zone exposure as direct but with hub recovery options. Best contingency if IST is disrupted.",
  watch_for: "AMS–DXB transits the active advisory zone. Monitor Gulf escalation. Emirates' high AMS frequency is the contingency advantage here.",
  explanation_bullets: [
    "AMS–DXB first leg transits the active advisory zone — same exposure as the direct option.",
    "Emirates provides the best first-leg rebooking depth of the three options.",
    "DXB–BOM is a short, clean segment with no advisory concerns."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Mumbai (3 corridor families: IST, direct, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → DELHI
# Three families: Turkey hub · Direct · Gulf (Dubai)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: del.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [del.lng, del.lat]]),
  distance_km: 8050, typical_duration_minutes: 615, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best balance for FRA→DEL. Avoids the advisory zone on both legs; Istanbul is well-placed between Frankfurt and Delhi.",
  ranking_context: "Top option: pressure score 77 vs 43–53 for other options. The advisory zone avoidance advantage over direct or Gulf options is clear.",
  watch_for: "IST–DEL routes over Iran/Pakistan — level-1 peripheral advisory. Turkish Airlines + Lufthansa feed well into this pairing.",
  explanation_bullets: [
    "FRA–IST uses standard European routing with no advisory exposure. IST–DEL routes via Iran/Pakistan with only peripheral level-1 exposure.",
    "Pressure score 77 vs 43 for the direct option — a 34-point improvement by avoiding the advisory zone.",
    "Hub dependency at Istanbul introduces connection risk; mitigated by strong Lufthansa–TK connectivity."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Lufthansa Direct",
  carrier_notes: "Lufthansa (LH) direct · Air India (AI) direct",
  path_geojson: line.([[fra.lng, fra.lat], [38.0, 32.0], [del.lng, del.lat]]),
  distance_km: 6690, typical_duration_minutes: 505, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Fastest option — direct, ~8.5 hours. The full sector crosses the Middle East advisory zone. Carrier choice is limited to Lufthansa and Air India.",
  ranking_context: "Structural score 85 but pressure is low (43) due to advisory zone transit and fewer carriers. Net composite 64 — just under the advisory cap threshold.",
  watch_for: "FRA–DEL direct transits the Middle East advisory zone for approximately 4 hours of the flight. Monitor Lufthansa and BMVI advisories.",
  explanation_bullets: [
    "No hub, no connection — simplest journey structure, no missed-flight risk.",
    "FRA–DEL crosses the active advisory zone for roughly 4 hours of the ~8.5-hour sector.",
    "Only Lufthansa and Air India operate non-stop — limited rebooking options if direct services are disrupted."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: del.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) / Air India (AI)",
  path_geojson: line.([[fra.lng, fra.lat], [dxb.lng, dxb.lat], [del.lng, del.lat]]),
  distance_km: 8400, typical_duration_minutes: 635, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Emirates via Dubai — most rebooking depth. FRA–DXB crosses the advisory zone. Best used as backup when Istanbul is full or disrupted.",
  ranking_context: "Scores 60 vs 72 for Istanbul. Advisory zone transit on the first leg is the differentiator; Emirates' frequency is the contingency advantage.",
  watch_for: "FRA–DXB transits the active Middle East advisory zone. Monitor Gulf escalation. Emirates has 5+ daily FRA–DXB departures.",
  explanation_bullets: [
    "FRA–DXB first leg crosses the active advisory zone — same exposure as flying direct through the Gulf corridor.",
    "Emirates' high FRA frequency gives the best first-leg rebooking depth of the three options.",
    "DXB–DEL is a short, clean segment (~3h) with no advisory concerns."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Delhi (3 corridor families: IST, direct, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → DELHI
# Three families: Turkey hub · Direct · Gulf (Dubai)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: del.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Air France (AF) + Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [del.lng, del.lat]]),
  distance_km: 8250, typical_duration_minutes: 630, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best balance for CDG→DEL. Avoids the advisory zone on both legs. Air France connects into Turkish Airlines' IST–DEL service.",
  ranking_context: "Top option on pressure (77 vs 53 for direct/Gulf). Same advisory zone avoidance logic as all European→India via Istanbul pairs.",
  watch_for: "IST–DEL routes over Iran/Pakistan — level-1 peripheral advisory. Check TK operational status if Turkey sees regional turbulence.",
  explanation_bullets: [
    "CDG–IST avoids advisory exposure entirely. IST–DEL routes via Iran with only peripheral level-1 exposure.",
    "Pressure score 77 vs 53 for the direct option — a material advantage from avoiding the advisory zone.",
    "Air France + Turkish Airlines + Air India all connect on this pairing — strong combined frequency."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Air France Direct",
  carrier_notes: "Air France (AF) direct · Air India (AI) direct",
  path_geojson: line.([[cdg.lng, cdg.lat], [40.0, 32.0], [del.lng, del.lat]]),
  distance_km: 6850, typical_duration_minutes: 520, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Fastest option — direct ~8.5 hours. The full sector transits the Middle East advisory zone. Air France and Air India both operate this non-stop.",
  ranking_context: "Structural score 85 (direct, no hub) but composite capped at 60 due to advisory zone transit. Fastest; highest airspace exposure.",
  watch_for: "CDG–DEL direct transits the Middle East advisory zone. Monitor DGAC and FCDO advisories before departure.",
  explanation_bullets: [
    "No hub, no connection — structurally the simplest journey with the lowest missed-flight risk.",
    "The CDG–DEL direct sector crosses the active advisory zone for approximately 4 hours.",
    "Air France and Air India both operate non-stop — adequate frequency, but rebooking alternatives require switching to a hub option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: del.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Air France (AF) + Emirates (EK) / Air India (AI)",
  path_geojson: line.([[cdg.lng, cdg.lat], [dxb.lng, dxb.lat], [del.lng, del.lat]]),
  distance_km: 8500, typical_duration_minutes: 645, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Emirates via Dubai — most rebooking depth. CDG–DXB crosses the advisory zone. Best backup when Istanbul is full or disrupted.",
  ranking_context: "Scores 60 vs 72 for Istanbul. Same advisory zone exposure as direct; Emirates' frequency gives better contingency options.",
  watch_for: "CDG–DXB transits the active advisory zone. Emirates has 4+ daily CDG–DXB departures — best first-leg rebooking depth of the three options.",
  explanation_bullets: [
    "CDG–DXB first leg crosses the active advisory zone — same core exposure as flying direct.",
    "Emirates provides the strongest first-leg rebooking depth on this pair.",
    "DXB–DEL is a short, clean segment with no advisory concerns."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Delhi (3 corridor families: IST, direct, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → MUMBAI
# Three families: Turkey hub · Direct · Gulf (Dubai)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: bom.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Air France (AF) + Turkish Airlines (TK) / Air India (AI)",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [bom.lng, bom.lat]]),
  distance_km: 8400, typical_duration_minutes: 645, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best balance for CDG→BOM. Avoids the advisory zone on both legs. Istanbul is well-placed between Paris and Mumbai.",
  ranking_context: "Top option: pressure score 77 vs 53 for other options. Avoids the advisory zone that the direct and Dubai options both transit on the first leg.",
  watch_for: "IST–BOM routes over Iran — level-1 peripheral advisory. Turkish Airlines has solid IST–BOM frequency.",
  explanation_bullets: [
    "CDG–IST avoids advisory exposure. IST–BOM routes via Iran with only peripheral level-1 exposure.",
    "Pressure score advantage (77 vs 53) is the core justification for choosing this over the direct or Dubai option.",
    "Air France + Turkish Airlines + Air India give strong combined frequency on this pairing."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Air France Direct",
  carrier_notes: "Air France (AF) direct · Air India (AI) direct",
  path_geojson: line.([[cdg.lng, cdg.lat], [42.0, 28.0], [bom.lng, bom.lat]]),
  distance_km: 7300, typical_duration_minutes: 555, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Fastest option — direct ~9 hours. The full sector transits the Middle East advisory zone. Use when simplicity matters more than airspace exposure.",
  ranking_context: "Structural score 85 but composite capped at 60 due to advisory zone transit. Fastest option; highest airspace exposure of the three.",
  watch_for: "CDG–BOM direct transits the Middle East advisory zone for approximately 5 hours. Monitor DGAC and FCDO advisories.",
  explanation_bullets: [
    "No hub, no connection — structurally the simplest option with the lowest missed-flight risk.",
    "The CDG–BOM sector crosses the active advisory zone for roughly 5 hours.",
    "Air France and Air India operate this non-stop — rebooking alternatives require switching to a hub routing."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: bom.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Air France (AF) + Emirates (EK) / Air India (AI)",
  path_geojson: line.([[cdg.lng, cdg.lat], [dxb.lng, dxb.lat], [bom.lng, bom.lat]]),
  distance_km: 9050, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Emirates via Dubai — most rebooking depth. CDG–DXB crosses the advisory zone. Best backup when Istanbul is full or disrupted.",
  ranking_context: "Scores 60 vs 72 for Istanbul. Same advisory zone exposure as direct, but hub break gives better recovery options if the CDG segment is disrupted.",
  watch_for: "CDG–DXB transits the active advisory zone. Emirates has 4+ daily CDG–DXB departures — best first-leg rebooking options on this pair.",
  explanation_bullets: [
    "CDG–DXB first leg crosses the active advisory zone — same core exposure as flying direct.",
    "Emirates' high CDG frequency is the main contingency advantage over the direct option.",
    "DXB–BOM is a short, clean segment with no advisory concerns."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Mumbai (3 corridor families: IST, direct, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → TOKYO
# Three families: North Asia (Seoul) · Turkey hub · Central Asia (KLM direct)
# Seoul wins here: ICN hub_score=0, short ICN→NRT leg, no Gulf exposure.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: nrt.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "KLM (KL) + Korean Air (KE) / ANA (NH) / Japan Airlines (JL)",
  path_geojson: line.([[ams.lng, ams.lat], [58.0, 44.0], [icn.lng, icn.lat], [nrt.lng, nrt.lat]]),
  distance_km: 10350, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best-rated option for AMS→NRT. No Gulf exposure; ICN is world-class with very high ICN→NRT frequency. The ICN→NRT second leg is only 2 hours.",
  ranking_context: "Ranks highest (70) because ICN hub scores 0/3 and the short ICN→NRT leg carries no advisory exposure. AMS→ICN first leg uses the Central Asian corridor — same constraint as the direct flight — but the hub break and short final leg reduce risk materially.",
  watch_for: "AMS→ICN uses the Central Asian corridor. Check Eurocontrol ATFM status before departure. ICN→NRT is clean, uncongested, and high-frequency.",
  explanation_bullets: [
    "ICN hub scores 0/3 — world-class, no regional conflict proximity. The structural advantage over Istanbul on this pair.",
    "ICN→NRT second leg is only ~2 hours via clean Korean/Japanese airspace — dramatically shorter than any alternative second leg.",
    "AMS→ICN first leg uses the Central Asian corridor. Hub break at Seoul gives recovery optionality if conditions change."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: nrt.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "KLM (KL) + Turkish Airlines (TK) / Japan Airlines (JL) / ANA (NH)",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [55.0, 40.0], [90.0, 40.0], [nrt.lng, nrt.lat]]),
  distance_km: 12350, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Better structural resilience than the direct flight — the hub break at Istanbul creates a decision point before committing to the Central Asian corridor second leg.",
  ranking_context: "Ranks second (65 vs 70 via Seoul): IST hub scores 1 vs ICN's 0 (regional proximity factor), and the IST→NRT second leg is 9+ hours through Central Asia vs ICN→NRT's 2 hours.",
  watch_for: "IST→NRT uses the Central Asian corridor. The hub break at Istanbul lets you assess corridor conditions before committing to the second leg.",
  explanation_bullets: [
    "Hub break at Istanbul creates structural optionality: you can assess corridor conditions before committing to the long IST→NRT segment.",
    "Corridor dependency rated 2/3 (not 3/3 like direct) because the IST hub creates a real decision point.",
    "KLM, Turkish Airlines, and Japan Airlines all operate on this pairing — good combined frequency."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "KLM Direct (Central Asian Routing)",
  carrier_notes: "KLM (KL) direct — rerouted via Central Asian corridor since 2022",
  path_geojson: line.([[ams.lng, ams.lat], [52.0, 46.0], [83.0, 46.0], [nrt.lng, nrt.lat]]),
  distance_km: 11700, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Fastest when the corridor is clear. No hub connection risk. But the entire route depends on the Central Asian corridor — high schedule variance with no reroute option if restricted.",
  ranking_context: "Sole-corridor dependency (3/3) defines the structural risk. On a clear day this is competitive on time; on a restriction day it incurs the longest delays with no alternative. Treat as high-variance, not default.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before every departure. KLM has reduced AMS–NRT frequency since 2022 — verify current schedule.",
  explanation_bullets: [
    "Corridor dependency 3/3 — the entire AMS–NRT route uses the Central Asian corridor with no viable alternative path.",
    "No hub means no missed connection risk but also no natural reroute point if the corridor is restricted.",
    "Pre-2022 AMS–NRT was ~12h via Russia. Current routing via Central Asia runs 14.5–15.5h depending on ATFM conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: nrt.id, via_hub_city_id: pek.id,
  corridor_family: "china_arc",
  route_name: "Via Beijing",
  carrier_notes: "Air China (CA) · AMS–PEK–NRT",
  path_geojson: line.([[ams.lng, ams.lat], [52.0, 46.0], [85.0, 44.0], [pek.lng, pek.lat], [nrt.lng, nrt.lat]]),
  distance_km: 10200, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Air China's China-side option for AMS→NRT. PEK→NRT is a short, clean segment (~3 hours) over Yellow Sea airspace. The AMS→PEK first leg uses the Central Asian corridor — same structural dependency as Via Istanbul and Via Seoul on this pair.",
  ranking_context: "Ranks similarly to Istanbul: both use the Central Asian corridor on the first leg and both hubs score 1/3. PEK→NRT (~3 hours) is shorter than IST→NRT (~9 hours via Central Asia) — a structural edge — but PRC hub context offsets this. Via Seoul remains the strongest option on this pair (ICN hub_score 0 vs PEK's 1).",
  watch_for: "AMS→PEK uses the Central Asian corridor — check Eurocontrol ATFM status before departure. Air China's AMS–PEK service frequency is lower than on London and Paris routes; verify current schedule before booking.",
  explanation_bullets: [
    "Air China operates AMS→PEK service connecting to multiple daily PEK→NRT frequencies — gives access to a real China-side alternative.",
    "PEK→NRT is only ~3 hours over clean Yellow Sea/East China Sea airspace with no active airspace advisories.",
    "AMS→PEK first leg uses the Central Asian corridor — the same structural constraint shared by Via Seoul and Via Istanbul on this pair.",
    "Beijing hub rated 1/3: strong operational track record, but PRC political and regulatory context means bilateral route access warrants monitoring.",
    "Total journey approximately 14.5 hours. Relevant for travellers with Air China status or those seeking China stopover options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Tokyo (4 corridor families: ICN, IST, central_asia, beijing/china_arc) — Seoul ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → SEOUL
# Three families: North Asia (HKG) · Turkey hub · Central Asia direct (KE)
# HKG wins: ICN hub is world-class, HKG→ICN second leg is only ~3.5h.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) + Korean Air (KE) / Asiana (OZ)",
  path_geojson: line.([[lhr.lng, lhr.lat], [52.0, 46.0], [85.0, 43.0], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 11300, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best-rated option for LHR→ICN. HKG→ICN second leg is only 3.5 hours via clean Korean airspace. No Gulf exposure on either leg.",
  ranking_context: "Ranks above Istanbul because HKG hub scores 0/3 vs IST's 1/3, and the HKG→ICN second leg is dramatically shorter than IST→ICN. Both use the Central Asian corridor on the first leg.",
  watch_for: "LHR→HKG depends on the Central Asian corridor. Check Eurocontrol ATFM status day-of. HKG→ICN is clean and high-frequency.",
  explanation_bullets: [
    "HKG→ICN is a 3.5-hour clean hop — Seoul's proximity to Hong Kong gives this routing a structural second-leg advantage over Istanbul.",
    "Neither leg touches the Middle East advisory zone: LHR→HKG via Central Asia, HKG→ICN via South China Sea.",
    "Cathay Pacific and Korean Air together provide 3+ daily HKG→ICN departures — strong recovery depth if the first leg delays."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: icn.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Korean Air (KE) / Asiana (OZ)",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [55.0, 40.0], [90.0, 40.0], [icn.lng, icn.lat]]),
  distance_km: 12600, typical_duration_minutes: 930, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Hub break at Istanbul before the long Central Asian corridor leg to Seoul. Lower advisory exposure than Gulf options.",
  ranking_context: "Ranks below HKG because IST hub scores 1/3 vs HKG's 0/3, and IST→ICN is a much longer second leg than HKG→ICN. Ranks above Gulf options because advisory exposure is 1 vs 2.",
  watch_for: "IST→ICN routes through the Central Asian corridor. Check ATFM status before the second leg departs Istanbul.",
  explanation_bullets: [
    "LHR→IST avoids the advisory zone entirely. IST→ICN uses the Central Asian corridor — level-1 advisory proximity, no current routing restriction.",
    "Istanbul hub provides a natural decision point: assess corridor conditions before committing to the 9+ hour second leg.",
    "Turkish Airlines and Korean Air both operate this routing with adequate combined frequency."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Korean Air Direct",
  carrier_notes: "Korean Air (KE) direct · 1 daily LHR–ICN via Central Asian corridor",
  path_geojson: line.([[lhr.lng, lhr.lat], [22.0, 44.0], [52.0, 46.0], [85.0, 43.0], [icn.lng, icn.lat]]),
  distance_km: 11000, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Most direct routing when the Central Asian corridor is clear. No connection risk, but entirely dependent on one corridor — high schedule variance.",
  ranking_context: "Corridor dependency 3/3 defines the structural constraint. Fastest option when conditions are good; highest delay variance if the corridor is restricted. Treat as schedule-sensitive, not default.",
  watch_for: "Entire route depends on the Central Asian corridor. Check Eurocontrol ATFM and KE advisories before departure. KE operates 1 daily LHR–ICN — limited rebooking flexibility.",
  explanation_bullets: [
    "Corridor dependency 3/3 — no alternative routing exists for Korean Air LHR–ICN. Clear conditions = fastest option; restrictions = no recovery path.",
    "Korean Air operates 1 daily LHR–ICN. Rebooking options are narrower than hub alternatives.",
    "Post-2022, this route adds approximately 2.5 hours vs pre-Russia-closure timing. Schedule variance has stabilised but remains higher than hub options."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Seoul (3 corridor families: HKG, IST, central_asia) — HKG ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → HONG KONG
# Three families: Turkey hub · Gulf · Central Asia direct (LH)
# Istanbul wins: IST→HKG avoids the advisory zone core; DXB transit is airspace=2.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: hkg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) / Cathay Pacific (CX)",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [52.0, 38.0], [85.0, 35.0], [hkg.lng, hkg.lat]]),
  distance_km: 10500, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best airspace profile for FRA→HKG. IST hub avoids Gulf exposure. IST→HKG routes via South/Central Asia without the advisory zone core.",
  ranking_context: "Ranks above Dubai because FRA→IST avoids the advisory zone entirely. The IST→HKG leg carries level-1 proximity — closer to the advisory zone than some options but no current restriction.",
  watch_for: "IST→HKG routes through Turkey → Iran → Pakistan → South Asia. Level-1 advisory proximity. If Iranian FIR restrictions tighten, this segment may add 30–45 minutes.",
  explanation_bullets: [
    "FRA→IST uses standard European routing south of Ukraine — clean and predictable.",
    "IST→HKG routes southeast via Iran/Pakistan/South Asia. Level-1 advisory proximity, no active routing restriction as of last review.",
    "Turkish Airlines + Cathay Pacific provide adequate combined frequency on this routing."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: hkg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) / Cathay Pacific (CX)",
  path_geojson: line.([[fra.lng, fra.lat], [25.0, 42.0], [40.0, 33.0], [dxb.lng, dxb.lat], [65.0, 22.0], [90.0, 22.0], [hkg.lng, hkg.lat]]),
  distance_km: 11200, typical_duration_minutes: 820, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates' rebooking depth is the advantage. FRA→DXB transits the active Middle East advisory zone — don't let the frequency obscure the airspace exposure.",
  ranking_context: "Ranked below Istanbul because the Frankfurt–Dubai first leg crosses the active advisory zone. DXB→HKG is clean. The structural advantage is Emirates' frequency depth.",
  watch_for: "FRA→DXB crosses the advisory zone. Monitor Levant/Gulf escalation. DXB hub has remained fully operational but rapid escalation could affect routing with minimal warning.",
  explanation_bullets: [
    "FRA→DXB first leg transits the active Middle East advisory zone — the main risk factor on this routing.",
    "Emirates operates 4+ daily FRA→DXB departures — strongest rebooking depth of any option on this pair if the first leg is disrupted.",
    "DXB→HKG is a clean 7-hour segment via South Asian airspace with no active advisory concerns."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Lufthansa Direct",
  carrier_notes: "Lufthansa (LH) direct · rerouted via Central Asian corridor since 2022",
  path_geojson: line.([[fra.lng, fra.lat], [52.0, 47.0], [82.0, 44.0], [hkg.lng, hkg.lat]]),
  distance_km: 10200, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Fastest when the corridor is clear. No connection risk but entire journey depends on the Central Asian corridor — Lufthansa operates reduced frequency.",
  ranking_context: "Corridor dependency 3/3 is the structural constraint. Competitive on time; higher delay variance than hub alternatives. Lufthansa reduced FRA–HKG frequency since 2022 — verify schedule.",
  watch_for: "Entire route depends on Central Asian corridor. Check Eurocontrol ATFM. Lufthansa reduced FRA–HKG frequency post-2022 — verify current schedule before booking.",
  explanation_bullets: [
    "Corridor dependency 3/3 — if the Central Asian corridor is restricted, there is no recovery path short of rebooking to a different routing entirely.",
    "Lufthansa operates this route with reduced post-2022 frequency. Rebooking depth is narrower than hub alternatives.",
    "Pre-2022 FRA–HKG via Siberia was ~10.5h. Current Central Asian routing runs ~12.5–13h."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Hong Kong (3 corridor families: IST, gulf_dubai, central_asia) — IST ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → LONDON
# Three families: North Asia (HKG, Gulf-free) · Gulf Dubai · Gulf Doha
# HKG wins: only option that keeps both legs clear of the advisory zone.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: lhr.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Singapore Airlines (SQ) + Cathay Pacific (CX) / British Airways (BA)",
  path_geojson: line.([[sin.lng, sin.lat], [hkg.lng, hkg.lat], [80.0, 44.0], [45.0, 46.0], [lhr.lng, lhr.lat]]),
  distance_km: 13100, typical_duration_minutes: 945, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Gulf-free option for SIN→LHR. Neither leg touches the active advisory zone — longer journey, cleaner airspace profile.",
  ranking_context: "Ranks first because it is the only option that avoids the advisory zone on both legs. HKG→LHR via Central Asian corridor is longer but structurally cleaner than both Gulf alternatives.",
  watch_for: "HKG→LHR depends on the Central Asian corridor. Check Eurocontrol ATFM status. SIN→HKG is clean and high-frequency with Cathay Pacific.",
  explanation_bullets: [
    "SIN→HKG is a 3.5-hour clean hop. HKG→LHR routes north via the Central Asian corridor — no Gulf transit on either leg.",
    "Cathay Pacific operates 4 daily SIN→HKG services. Good recovery depth at HKG with strong LHR onward options.",
    "Total journey is approximately 16–17 hours — roughly 1.5 hours longer than Gulf options. A reasonable premium to avoid advisory zone exposure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Singapore Airlines (SQ) + Emirates",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 11600, typical_duration_minutes: 855, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Most frequency and rebooking options on SIN→LHR. SIN→DXB first leg is clean; the DXB→LHR return leg crosses the active advisory zone.",
  ranking_context: "Ranked below HKG because the Dubai–London second leg transits the advisory zone. Highest frequency of any SIN→LHR routing — use when schedule flexibility matters.",
  watch_for: "DXB→LHR transits the active advisory zone. Emirates and SQ combined provide 6+ daily SIN→DXB departures — strong first-leg rebooking options.",
  explanation_bullets: [
    "SIN→DXB first leg is clean. The advisory zone exposure is on the DXB→LHR second segment.",
    "Emirates and Singapore Airlines combined provide 6+ daily SIN→DXB departures — the highest frequency on this corridor.",
    "DXB hub has maintained full operations throughout current regional tensions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: lhr.id, via_hub_city_id: c["Doha"].id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily SIN–DOH–LHR",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [c["Doha"].lng, c["Doha"].lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 11400, typical_duration_minutes: 845, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' SIN–LHR service via Doha. Strong QR frequency on both legs. DOH→LHR crosses the advisory zone — same structural exposure as the Dubai option.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). Same advisory zone exposure on the second leg. Choice between Doha and Dubai is carrier preference, not risk profile.",
  watch_for: "DOH→LHR crosses the active advisory zone. Qatar Airways maintains full operations but monitor escalation in the Levant/Gulf region.",
  explanation_bullets: [
    "SIN→DOH first leg routes through South Asian airspace — clean, no active advisory exposure.",
    "Qatar Airways operates 3 daily SIN→DOH services with LHR connections — strong frequency.",
    "Advisory zone exposure is on DOH→LHR, identical structural exposure to the Dubai option."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → London (3 corridor families: north_asia_hkg, gulf_dubai, gulf_doha) — HKG ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# JAKARTA → FRANKFURT
# Three families: South Asia (SIN) · North Asia (HKG) · Gulf Dubai
# SIN wins: natural geographic waypoint, world-class hub, Gulf-free routing.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: fra.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) + Lufthansa (LH) / Garuda Indonesia (GA)",
  path_geojson: line.([[cgk.lng, cgk.lat], [sin.lng, sin.lat], [75.0, 20.0], [45.0, 35.0], [fra.lng, fra.lat]]),
  distance_km: 11200, typical_duration_minutes: 825, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Top-rated option for CGK→FRA. Singapore is the natural geographic waypoint — short first leg, world-class hub, and SIN→FRA avoids Gulf airspace.",
  ranking_context: "Ranks first (81, :flowing). Singapore hub scores 0/3, corridor alternatives exist, and the routing avoids the advisory zone on both legs. Strongest structural profile on this pair.",
  watch_for: "SIN→FRA routes via Central Asian corridor post-2022. Check Eurocontrol ATFM day-of for any corridor restrictions on the long second leg.",
  explanation_bullets: [
    "CGK→SIN is a 90-minute clean hop. SIN→FRA routes via South Asia and the Central Asian corridor — no Gulf advisory zone exposure.",
    "Singapore Changi hub scores 0/3: world-class recovery optionality if CGK departure is delayed.",
    "Singapore Airlines and Lufthansa both operate on this routing, providing 3+ daily SIN→FRA options — strong combined frequency."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: fra.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) + Lufthansa (LH) / Austrian Airlines (OS)",
  path_geojson: line.([[cgk.lng, cgk.lat], [hkg.lng, hkg.lat], [80.0, 42.0], [45.0, 46.0], [fra.lng, fra.lat]]),
  distance_km: 12200, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Gulf-free alternative via Cathay's hub. HKG is a small northward detour from CGK, but HKG→FRA via Central Asia is competitive and avoids the advisory zone.",
  ranking_context: "Ranks second (73, :watchful). HKG hub quality matches SIN, but the northward diversion adds complexity and Cathay + Lufthansa combined frequency is narrower than SIN option.",
  watch_for: "HKG→FRA depends on the Central Asian corridor. Cathay Pacific frequency at HKG is strong; ATFM corridor restrictions on the second leg are the main variance factor.",
  explanation_bullets: [
    "CGK→HKG is a 4-hour clean hop north. HKG→FRA routes via the Central Asian corridor — fully Gulf-free.",
    "Cathay Pacific + Lufthansa codeshare on this routing. HKG hub has maintained strong post-2022 operational resilience.",
    "The northward diversion to HKG adds approximately 2 hours to total journey vs routing directly through Singapore."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily CGK–DXB–FRA",
  path_geojson: line.([[cgk.lng, cgk.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [30.0, 40.0], [fra.lng, fra.lat]]),
  distance_km: 11900, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Emirates' rebooking depth is the advantage. CGK→DXB first leg is clean; the DXB→FRA second leg crosses the active advisory zone.",
  ranking_context: "Ranks third (63, :watchful). Advisory zone exposure on the DXB→FRA leg differentiates it from the Singapore and HKG options. Use when Emirates frequency or schedule fits better.",
  watch_for: "DXB→FRA transits the active advisory zone. Emirates has 4+ daily CGK→DXB departures — strong first-leg rebooking options if the Jakarta segment is disrupted.",
  explanation_bullets: [
    "CGK→DXB first leg routes through South Asian airspace — clean, no advisory concerns.",
    "The advisory zone exposure is on DXB→FRA. Emirates maintains full DXB operations but the corridor carries active advisory risk.",
    "Emirates provides the highest combined frequency on this routing: 4+ daily CGK→DXB with multiple FRA connections."
  ],
  calculated_at: now
})

IO.puts("  ✓ Jakarta → Frankfurt (3 corridor families: south_asia_direct, north_asia_hkg, gulf_dubai) — SIN ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → AMSTERDAM
# Three families: Direct (Central Asian corridor) · Gulf Dubai · Gulf Doha
# Direct wins: SIA non-stop avoids Gulf advisory zone on both legs.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: ams.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Singapore Airlines Direct",
  carrier_notes: "Singapore Airlines (SQ) · 1 daily SIN–AMS non-stop / KLM (KL) codeshare",
  path_geojson: line.([[sin.lng, sin.lat], [75.0, 15.0], [52.0, 35.0], [22.0, 45.0], [ams.lng, ams.lat]]),
  distance_km: 10850, typical_duration_minutes: 810, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Best option for SIN→AMS. Non-stop via the Central Asian corridor avoids Gulf advisory zone on both ends. No connection risk at an intermediate hub.",
  ranking_context: "Ranks first: only option that avoids the advisory zone entirely. SIA direct is ~1.5h longer than in-era pre-2022 schedules, but structurally cleaner than Gulf alternatives. No hub dependency is the tiebreaker.",
  watch_for: "SIN→AMS routes via the Central Asian corridor — check Eurocontrol ATFM status on departure day. SQ is the sole non-stop carrier so rebooking onto a direct flight is not possible if this service is disrupted.",
  explanation_bullets: [
    "Singapore Airlines' SIN–AMS non-stop avoids Gulf airspace entirely — the route tracks northwest via South Asia and the Central Asian corridor.",
    "No hub connection means no missed connection risk, no layover, and no intermediate hub vulnerability — structurally the simplest journey.",
    "SQ operates 1 daily SIN–AMS departure with KLM codeshare inventory. If disrupted, the fallback is a Gulf hub connection, so monitor departure status."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily SIN–DXB, multiple DXB–AMS departures",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 12100, typical_duration_minutes: 930, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Highest rebooking flexibility on SIN→AMS. SIN→DXB first leg is clean; DXB→AMS second leg crosses the active advisory zone.",
  ranking_context: "Ranks below the direct option due to advisory zone exposure on the DXB→AMS leg. Best choice if SQ is unavailable or if Emirates' superior frequency at SIN–DXB makes rebooking essential.",
  watch_for: "DXB→AMS transits the active Middle East advisory zone. Emirates' SIN–DXB frequency is high — strong first-leg rebooking options if departure disrupted.",
  explanation_bullets: [
    "SIN→DXB first leg routes through clean South Asian airspace. Advisory zone exposure is on DXB→AMS.",
    "Emirates operates 4+ daily SIN→DXB departures — the highest frequency on this corridor, giving strong day-of rebooking flexibility.",
    "Total journey is approximately 2 hours longer than the direct option, including layover time at DXB."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: ams.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily SIN–DOH–AMS",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [doh.lng, doh.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 11800, typical_duration_minutes: 905, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' SIN–AMS via Doha. Same advisory zone exposure as the Dubai option on the second leg — choice is carrier preference.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→AMS carries identical advisory zone exposure to DXB→AMS. Neither Gulf option matches the direct route's clean airspace profile.",
  watch_for: "DOH→AMS transits the active advisory zone. Qatar Airways maintains full DOH operations but the second leg carries real advisory exposure.",
  explanation_bullets: [
    "SIN→DOH first leg is clean — routes through South Asian airspace with no advisory concerns.",
    "Qatar Airways operates 3 daily SIN→DOH services with AMS connections — solid frequency on both legs.",
    "Advisory zone exposure is on DOH→AMS, identical structural risk to the Dubai option. No meaningful disruption-profile difference between the two Gulf options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Amsterdam (3 corridor families: direct, gulf_dubai, gulf_doha) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → FRANKFURT
# Three families: Direct (Central Asian corridor) · Gulf Dubai · Gulf Doha
# Direct wins: Lufthansa/SIA non-stop is Gulf-free on both legs.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: fra.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Singapore Airlines / Lufthansa Direct",
  carrier_notes: "Singapore Airlines (SQ) · 1 daily SIN–FRA / Lufthansa (LH) codeshare",
  path_geojson: line.([[sin.lng, sin.lat], [75.0, 15.0], [52.0, 35.0], [22.0, 46.0], [fra.lng, fra.lat]]),
  distance_km: 10200, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Best option for SIN→FRA. Non-stop via the Central Asian corridor avoids Gulf advisory zone entirely. Lufthansa codeshare provides additional ticketing options.",
  ranking_context: "Ranks first: Gulf-free routing with no hub connection required. SIN→FRA is ~1 hour shorter than SIN→AMS, making the Central Asian corridor detour less burdensome. No hub dependency is the structural advantage.",
  watch_for: "SIN→FRA routes via the Central Asian corridor — check Eurocontrol ATFM on departure day. Sole non-stop operators are SQ and LH; no alternative non-stop carrier if this service is disrupted.",
  explanation_bullets: [
    "Singapore Airlines' SIN–FRA non-stop tracks northwest via South Asia and the Central Asian corridor — no Gulf transit on either leg.",
    "At ~13 hours, SIN→FRA is among the shorter ultra-long-haul segments on this corridor, keeping schedule variance more manageable.",
    "Lufthansa codeshare provides access to LH's Frankfurt connection network onward — useful if continuing within Europe from FRA."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily SIN–DXB, multiple DXB–FRA departures",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [28.0, 40.0], [fra.lng, fra.lat]]),
  distance_km: 11500, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative for SIN→FRA. SIN→DXB first leg is clean; DXB→FRA second leg crosses the active advisory zone.",
  ranking_context: "Ranks below the direct option due to advisory zone exposure on DXB→FRA. Emirates and Lufthansa combined offer more departure options at SIN than SQ/LH alone — useful when timing flexibility matters.",
  watch_for: "DXB→FRA transits the active Middle East advisory zone. Emirates frequency on SIN–DXB is strong — first-leg rebooking depth is good if SIN departure is disrupted.",
  explanation_bullets: [
    "SIN→DXB first leg routes through clean South Asian airspace. Advisory zone exposure is on the DXB→FRA second leg.",
    "Emirates provides 4+ daily SIN→DXB departures — the strongest day-of rebooking depth of any SIN→FRA routing option.",
    "Journey is approximately 2 hours longer than the direct option when including layover at DXB."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: fra.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily SIN–DOH–FRA",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [doh.lng, doh.lat], [28.0, 40.0], [fra.lng, fra.lat]]),
  distance_km: 11200, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' SIN–FRA via Doha. Same advisory zone structure as the Dubai option — choice is carrier preference between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→FRA carries identical advisory zone exposure to DXB→FRA. Neither Gulf option matches the direct route's airspace profile.",
  watch_for: "DOH→FRA transits the active advisory zone. Qatar Airways maintains full DOH operations but the second leg carries real exposure.",
  explanation_bullets: [
    "SIN→DOH first leg is clean — routes through South Asian airspace with no active advisory exposure.",
    "Qatar Airways operates 3 daily SIN→DOH services with onward FRA connections.",
    "Advisory zone exposure on DOH→FRA is structurally identical to the Dubai option. This is a carrier choice, not a risk profile choice."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Frankfurt (3 corridor families: direct, gulf_dubai, gulf_doha) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → KUALA LUMPUR
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: kul.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily LHR–IST–KUL",
  path_geojson: line.([[lhr.lng, lhr.lat], [ist.lng, ist.lat], [kul.lng, kul.lat]]),
  distance_km: 10800, typical_duration_minutes: 825, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best current option for LHR→KUL. Avoids the Middle East advisory zone on both legs. Turkish Airlines' IST–KUL service is reliable and well-connected.",
  ranking_context: "Top pick: IST keeps both legs out of the advisory zone. LHR–IST and IST–KUL are among TK's highest-volume routes — rebooking depth is good.",
  watch_for: "IST–KUL routes via South Asian airspace with level-1 peripheral exposure. TK has 4+ daily IST–KUL services for rebooking depth.",
  explanation_bullets: [
    "LHR–IST is a core European leg with no advisory exposure. IST–KUL routes east with only peripheral level-1 exposure.",
    "Turkish Airlines operates 2 daily LHR–IST departures with strong onward connections to Kuala Lumpur.",
    "Kuala Lumpur hub is fully operational; KUL sits in clean Southeast Asian airspace."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: kul.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily LHR–DXB, multiple DXB–KUL departures",
  path_geojson: line.([[lhr.lng, lhr.lat], [dxb.lng, dxb.lat], [kul.lng, kul.lat]]),
  distance_km: 11200, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. LHR–DXB crosses the active advisory zone — use when timing or Emirates loyalty is the priority.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to advisory zone exposure on LHR–DXB. Emirates' frequency gives the strongest day-of rebooking options.",
  watch_for: "LHR–DXB transits the active Middle East advisory zone. Emirates maintains full operations but regional escalation could affect routing with limited notice.",
  explanation_bullets: [
    "LHR–DXB first leg crosses the active advisory zone — the defining risk factor for this option.",
    "Emirates operates 4 daily LHR–DXB departures — strongest rebooking depth of any LHR→KUL routing.",
    "DXB–KUL second leg is clean; Kuala Lumpur sits in Southeast Asian airspace with no active concerns."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: kul.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily LHR–DOH–KUL",
  path_geojson: line.([[lhr.lng, lhr.lat], [doh.lng, doh.lat], [kul.lng, kul.lat]]),
  distance_km: 10900, typical_duration_minutes: 845, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' LHR–KUL via Doha. Same advisory exposure as the Dubai option — choose on carrier preference between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). LHR–DOH carries the same advisory zone exposure as LHR–DXB. This is a carrier choice.",
  watch_for: "LHR–DOH transits the active advisory zone. Qatar Airways maintains full DOH operations; monitor QR alerts if the Levant situation escalates.",
  explanation_bullets: [
    "LHR–DOH first leg crosses the advisory zone — identical exposure profile to the Dubai option.",
    "Qatar Airways operates 3 daily LHR–DOH–KUL services with strong DOH connectivity.",
    "DOH–KUL second leg is clean; Qatar Airways has good frequency on this segment."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Kuala Lumpur (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → LONDON
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: lhr.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 4+ daily IST–BKK, 2 daily IST–LHR",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [lhr.lng, lhr.lat]]),
  distance_km: 9450, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best current option for BKK→LHR. Avoids the Middle East advisory zone on both legs. IST hub has strong frequency in both directions.",
  ranking_context: "Top pick: both legs stay outside the advisory zone. Turkish Airlines operates 4+ daily IST–BKK services and 2 daily IST–LHR — one of the highest-frequency BKK→LHR combinations.",
  watch_for: "BKK–IST routes west via South Asian airspace with peripheral level-1 exposure. TK frequency means strong day-of recovery options.",
  explanation_bullets: [
    "BKK–IST routes via South Asian airspace with only level-1 peripheral advisory exposure.",
    "IST–LHR is a core TK route with no advisory zone crossing — a clean second leg.",
    "Turkish Airlines' Istanbul hub is the deepest rebooking pool for this route pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily BKK–DXB, 4 daily DXB–LHR",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 9600, typical_duration_minutes: 755, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates. DXB–LHR second leg crosses the active advisory zone — strong rebooking depth if disruption occurs.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to DXB–LHR advisory zone exposure. Emirates frequency on both BKK–DXB and DXB–LHR is the strongest of any Gulf option.",
  watch_for: "DXB–LHR transits the active Middle East advisory zone. Emirates has maintained full service but regional escalation could affect routing.",
  explanation_bullets: [
    "BKK–DXB first leg is clean. Advisory zone exposure is on the DXB–LHR second leg.",
    "Emirates operates 4 daily BKK–DXB and 4 daily DXB–LHR departures — strongest day-of rebooking depth.",
    "Journey is approximately 1.5 hours longer than the Istanbul option when including layover."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: lhr.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily BKK–DOH–LHR",
  path_geojson: line.([[bkk.lng, bkk.lat], [doh.lng, doh.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 9400, typical_duration_minutes: 740, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' BKK–LHR via Doha. Same advisory exposure as via Dubai — choose on carrier preference between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH–LHR carries the same advisory zone exposure as DXB–LHR. Carrier choice.",
  watch_for: "DOH–LHR transits the active advisory zone. Doha is geographically proximate to the Levant — monitor QR alerts if the situation escalates.",
  explanation_bullets: [
    "BKK–DOH first leg is clean. DOH–LHR second leg crosses the advisory zone — identical exposure to the Dubai option.",
    "Qatar Airways operates 3 daily BKK–DOH services with strong onward LHR connections.",
    "QR's Doha hub has strong connectivity but sits closer to the Levant situation than DXB."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → London (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → AMSTERDAM
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: ams.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 4+ daily BKK–IST, 3 daily IST–AMS",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [ams.lng, ams.lat]]),
  distance_km: 9350, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best current option for BKK→AMS. Both legs avoid the advisory zone. Turkish Airlines' IST hub is a natural waypoint with high frequency in both directions.",
  ranking_context: "Top pick: airspace-clean on both legs. TK operates 4+ daily BKK–IST and 3 daily IST–AMS — strongest frequency pairing for this route.",
  watch_for: "BKK–IST has peripheral level-1 exposure via South Asian airspace. TK frequency ensures strong recovery options.",
  explanation_bullets: [
    "BKK–IST routes west via South Asian airspace with only peripheral advisory exposure.",
    "IST–AMS is a core European TK route with no advisory zone crossing.",
    "Turkish Airlines' frequency on both segments gives the best day-of rebooking options."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily BKK–DXB, multiple DXB–AMS departures",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 9700, typical_duration_minutes: 765, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. DXB–AMS second leg crosses the active advisory zone — use when Emirates frequency or loyalty is the priority.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to DXB–AMS advisory zone exposure. Emirates' rebooking depth on both BKK–DXB and DXB–AMS is the strongest of the Gulf options.",
  watch_for: "DXB–AMS transits the active Middle East advisory zone. Emirates has maintained full operations but regional escalation could affect routing.",
  explanation_bullets: [
    "BKK–DXB first leg is clean. Advisory zone exposure is on the DXB–AMS second leg.",
    "Emirates operates 4 daily BKK–DXB departures — best first-leg rebooking depth of any option.",
    "DXB–AMS is a busy Emirates trunk route with multiple daily departures."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: ams.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily BKK–DOH–AMS",
  path_geojson: line.([[bkk.lng, bkk.lat], [doh.lng, doh.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 9500, typical_duration_minutes: 745, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' BKK–AMS via Doha. Same advisory exposure as via Dubai — carrier preference determines the choice between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH–AMS carries the same advisory zone exposure as DXB–AMS. This is a carrier choice, not a risk profile choice.",
  watch_for: "DOH–AMS transits the active advisory zone. Qatar Airways maintains full operations; monitor QR alerts if Levant tensions escalate.",
  explanation_bullets: [
    "BKK–DOH first leg is clean. DOH–AMS second leg crosses the advisory zone — same exposure as the Dubai option.",
    "Qatar Airways operates 3 daily BKK–DOH–AMS services with strong connectivity.",
    "Advisory exposure on DOH–AMS is structurally identical to DXB–AMS. Choose on airline preference."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Amsterdam (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → FRANKFURT
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: fra.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 4+ daily BKK–IST, 3 daily IST–FRA",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [fra.lng, fra.lat]]),
  distance_km: 9200, typical_duration_minutes: 715, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best current option for BKK→FRA. Both legs avoid the advisory zone. Turkish Airlines' high frequency on IST–FRA keeps recovery options strong.",
  ranking_context: "Top pick: IST keeps both legs outside the advisory zone, and TK operates 3 daily IST–FRA departures — more options than Lufthansa's own service can offer at this hub.",
  watch_for: "BKK–IST has peripheral level-1 exposure via South Asian airspace. TK's 4+ daily BKK–IST frequency ensures strong recovery options.",
  explanation_bullets: [
    "BKK–IST routes west with only peripheral advisory exposure. IST–FRA is a core European route — no advisory crossing.",
    "Turkish Airlines operates 3 daily IST–FRA services, giving strong rebooking depth on the second leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily BKK–DXB, multiple DXB–FRA departures",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [28.0, 40.0], [fra.lng, fra.lat]]),
  distance_km: 9500, typical_duration_minutes: 750, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. DXB–FRA second leg crosses the advisory zone — use when Emirates frequency or loyalty is the priority.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to DXB–FRA advisory zone exposure. Emirates' 4 daily BKK–DXB departures give the best first-leg rebooking depth.",
  watch_for: "DXB–FRA transits the active Middle East advisory zone. Emirates has maintained full operations but regional escalation could affect routing.",
  explanation_bullets: [
    "BKK–DXB first leg is clean. Advisory zone exposure is on the DXB–FRA second leg.",
    "Emirates operates 4 daily BKK–DXB departures — strongest day-of rebooking depth for this pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: fra.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily BKK–DOH–FRA",
  path_geojson: line.([[bkk.lng, bkk.lat], [doh.lng, doh.lat], [28.0, 40.0], [fra.lng, fra.lat]]),
  distance_km: 9300, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' BKK–FRA via Doha. Same advisory exposure as via Dubai — choose on carrier preference between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH–FRA carries the same advisory zone exposure as DXB–FRA. This is a carrier choice.",
  watch_for: "DOH–FRA transits the active advisory zone. Qatar Airways maintains full operations; monitor QR alerts if Levant tensions escalate.",
  explanation_bullets: [
    "BKK–DOH first leg is clean. DOH–FRA second leg crosses the advisory zone — same exposure as the Dubai option.",
    "Qatar Airways operates 3 daily BKK–DOH services with strong onward FRA connections."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Frankfurt (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → PARIS
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: cdg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 4+ daily BKK–IST, 2 daily IST–CDG",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [cdg.lng, cdg.lat]]),
  distance_km: 9400, typical_duration_minutes: 725, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best current option for BKK→CDG. Both legs avoid the advisory zone. IST–CDG has solid frequency for reliable connections.",
  ranking_context: "Top pick: both legs stay outside the advisory zone. TK's 4+ daily BKK–IST services and 2 daily IST–CDG departures give good overall rebooking options.",
  watch_for: "BKK–IST has peripheral level-1 exposure via South Asian airspace. IST–CDG is a standard European route with no advisory concerns.",
  explanation_bullets: [
    "BKK–IST routes with only peripheral advisory exposure. IST–CDG is a core European leg — clean airspace.",
    "Turkish Airlines covers both legs with reasonable frequency, making mid-journey recovery feasible."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily BKK–DXB, multiple DXB–CDG departures",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [28.0, 40.0], [cdg.lng, cdg.lat]]),
  distance_km: 9700, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. DXB–CDG second leg crosses the advisory zone — use when Emirates frequency or loyalty is the priority.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to DXB–CDG advisory zone exposure. Emirates' frequency on BKK–DXB is the highest of any BKK→CDG carrier.",
  watch_for: "DXB–CDG transits the active Middle East advisory zone. Emirates has maintained full operations but regional escalation could affect routing.",
  explanation_bullets: [
    "BKK–DXB first leg is clean. Advisory zone exposure is on the DXB–CDG second leg.",
    "Emirates operates 4 daily BKK–DXB departures — strongest rebooking depth for the first leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: cdg.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily BKK–DOH–CDG",
  path_geojson: line.([[bkk.lng, bkk.lat], [doh.lng, doh.lat], [28.0, 40.0], [cdg.lng, cdg.lat]]),
  distance_km: 9500, typical_duration_minutes: 740, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' BKK–CDG via Doha. Same advisory exposure as via Dubai — choose on carrier preference between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH–CDG carries the same advisory zone exposure as DXB–CDG. Carrier choice.",
  watch_for: "DOH–CDG transits the active advisory zone. Qatar Airways maintains full operations; monitor QR alerts if Levant tensions escalate.",
  explanation_bullets: [
    "BKK–DOH first leg is clean. DOH–CDG second leg crosses the advisory zone — same exposure as the Dubai option.",
    "Qatar Airways operates 3 daily BKK–DOH–CDG services with strong DOH connectivity to Paris."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Paris (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# KUALA LUMPUR → LONDON
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: lhr.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily KUL–IST–LHR",
  path_geojson: line.([[kul.lng, kul.lat], [ist.lng, ist.lat], [lhr.lng, lhr.lat]]),
  distance_km: 10800, typical_duration_minutes: 825, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best current option for KUL→LHR. Both legs avoid the advisory zone. Turkish Airlines is the most direct IST-connected carrier for this pair.",
  ranking_context: "Top pick: IST keeps both legs out of the advisory zone. KUL–IST and IST–LHR are both core TK routes with solid frequency.",
  watch_for: "KUL–IST routes with peripheral level-1 exposure via South Asian airspace. TK has 2 daily KUL–IST services for rebooking.",
  explanation_bullets: [
    "KUL–IST routes west with only peripheral advisory exposure. IST–LHR is a core European route — clean airspace.",
    "Turkish Airlines' Istanbul hub is the deepest rebooking pool for this route pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · multiple daily KUL–DXB, 4 daily DXB–LHR",
  path_geojson: line.([[kul.lng, kul.lat], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 11200, typical_duration_minutes: 875, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. DXB–LHR second leg crosses the advisory zone — use when Emirates frequency or loyalty is the priority.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to DXB–LHR advisory zone exposure. Emirates frequency on DXB–LHR is 4 daily — strongest second-leg rebooking depth.",
  watch_for: "DXB–LHR transits the active Middle East advisory zone. Emirates has maintained full service but regional escalation could affect routing.",
  explanation_bullets: [
    "KUL–DXB first leg is clean. Advisory zone exposure is on the DXB–LHR second leg.",
    "Emirates operates 4 daily DXB–LHR departures — the strongest second-leg rebooking depth of any option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: lhr.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily KUL–DOH–LHR",
  path_geojson: line.([[kul.lng, kul.lat], [doh.lng, doh.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 10900, typical_duration_minutes: 848, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' KUL–LHR via Doha. Same advisory exposure as via Dubai — carrier preference determines the choice between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH–LHR carries the same advisory zone exposure as DXB–LHR. Carrier choice.",
  watch_for: "DOH–LHR transits the active advisory zone. Doha sits geographically close to the Levant — monitor QR alerts if tensions escalate.",
  explanation_bullets: [
    "KUL–DOH first leg is clean. DOH–LHR second leg crosses the advisory zone — same exposure as the Dubai option.",
    "Qatar Airways operates 3 daily KUL–DOH–LHR services with competitive frequency."
  ],
  calculated_at: now
})

IO.puts("  ✓ Kuala Lumpur → London (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# KUALA LUMPUR → AMSTERDAM
# Three families: turkey_hub (IST) · gulf_dubai (DXB) · gulf_doha (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: ams.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily KUL–IST, 3 daily IST–AMS",
  path_geojson: line.([[kul.lng, kul.lat], [ist.lng, ist.lat], [ams.lng, ams.lat]]),
  distance_km: 10700, typical_duration_minutes: 815, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Most reliable KUL→AMS corridor. Both legs avoid the advisory zone. Istanbul is a natural waypoint on this route geometry.",
  ranking_context: "Top pick: avoids the advisory zone on both legs and the geometry fits well. IST–AMS has 3 daily TK departures — solid second-leg depth.",
  watch_for: "KUL–IST has peripheral level-1 exposure via South Asian airspace. TK frequency on both legs makes recovery manageable.",
  explanation_bullets: [
    "KUL–IST routes west with only peripheral advisory exposure. IST–AMS is a core TK European route — clean.",
    "Turkish Airlines is the only carrier linking both KUL and AMS through Istanbul with daily service on both legs."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · multiple daily KUL–DXB, multiple DXB–AMS departures",
  path_geojson: line.([[kul.lng, kul.lat], [dxb.lng, dxb.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 11000, typical_duration_minutes: 860, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates. DXB–AMS second leg crosses the advisory zone — use when Emirates frequency or loyalty is the priority.",
  ranking_context: "Ranks below Istanbul (63 vs 75) due to DXB–AMS advisory zone exposure. Emirates' rebooking depth on both KUL–DXB and DXB–AMS is the strongest of any Gulf option.",
  watch_for: "DXB–AMS transits the active Middle East advisory zone. Emirates has maintained full operations but regional escalation could affect routing.",
  explanation_bullets: [
    "KUL–DXB first leg is clean. Advisory zone exposure is on the DXB–AMS second leg.",
    "Emirates operates multiple daily KUL–DXB and DXB–AMS departures — deepest rebooking pool of any option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: ams.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily KUL–DOH–AMS",
  path_geojson: line.([[kul.lng, kul.lat], [doh.lng, doh.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 10800, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' KUL–AMS via Doha. Same advisory exposure as via Dubai — carrier preference determines the choice between QR and EK.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH–AMS carries the same advisory zone exposure as DXB–AMS. This is a carrier choice.",
  watch_for: "DOH–AMS transits the active advisory zone. Qatar Airways maintains full operations; monitor QR alerts if Levant tensions escalate.",
  explanation_bullets: [
    "KUL–DOH first leg is clean. DOH–AMS second leg crosses the advisory zone — identical exposure to the Dubai option.",
    "Qatar Airways operates 3 daily KUL–DOH–AMS services with strong DOH connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Kuala Lumpur → Amsterdam (3 corridor families: turkey_hub, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → LONDON
# Three families: central_asia (direct CX/BA) · Gulf Dubai · Gulf Doha
# Central Asia wins: nonstop avoids Gulf on both ends.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct via Central Asia",
  carrier_notes: "Cathay Pacific (CX) / British Airways (BA) · nonstop HKG–LHR",
  path_geojson: line.([[hkg.lng, hkg.lat], [80.0, 44.0], [45.0, 46.0], [lhr.lng, lhr.lat]]),
  distance_km: 9630, typical_duration_minutes: 745, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for HKG→LHR. Nonstop via Central Asian corridor avoids Gulf airspace on both legs. CX and BA offer strong daily frequencies.",
  ranking_context: "Ranks first: only option that keeps both ends clear of the advisory zone. No hub connection risk — structurally the simplest journey.",
  watch_for: "Central Asian corridor has some peripheral advisory proximity. Check Eurocontrol ATFM status on departure day for any flow restrictions.",
  explanation_bullets: [
    "HKG→LHR nonstop tracks northwest via Central Asian airspace — no Gulf or Middle East advisory zone transit.",
    "Cathay Pacific and British Airways each operate daily nonstop HKG–LHR services, giving solid rebooking depth.",
    "Central Asian corridor carries peripheral level-1 advisory proximity — not through any active advisory zone."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Cathay Pacific (CX) + Emirates via DXB",
  path_geojson: line.([[hkg.lng, hkg.lat], [72.0, 21.0], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 11400, typical_duration_minutes: 875, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates. HKG→DXB first leg is clean; DXB→LHR crosses the active advisory zone.",
  ranking_context: "Ranked below the direct option due to advisory zone exposure on the DXB→LHR leg. Emirates' DXB hub has the deepest rebooking pool on this corridor.",
  watch_for: "DXB→LHR transits the active Middle East advisory zone. Emirates has maintained full service but monitor escalation if routing via the Gulf.",
  explanation_bullets: [
    "HKG→DXB first leg routes through South Asian airspace — clean, no active advisory exposure.",
    "Emirates provides the highest frequency on DXB→LHR of any Gulf option — strong day-of rebooking depth.",
    "Advisory zone exposure is on the DXB→LHR second leg only."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: lhr.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 2 daily HKG–DOH–LHR",
  path_geojson: line.([[hkg.lng, hkg.lat], [72.0, 21.0], [doh.lng, doh.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 11200, typical_duration_minutes: 860, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' HKG–LHR via Doha. Same advisory exposure as Dubai on the second leg — choose on carrier preference.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→LHR carries the same advisory zone exposure as DXB→LHR.",
  watch_for: "DOH→LHR transits the active advisory zone. QR maintains full Doha operations but the second leg carries real advisory exposure.",
  explanation_bullets: [
    "HKG→DOH first leg is clean. Advisory zone exposure is on the DOH→LHR second leg.",
    "Qatar Airways operates 2 daily HKG→DOH services with LHR connections.",
    "Identical advisory exposure profile to the Dubai option — carrier preference decides between them."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → London (3 corridor families: central_asia, gulf_dubai, gulf_doha) — central_asia ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → AMSTERDAM
# Three families: central_asia (direct CX/KLM) · Gulf Dubai · Gulf Doha
# Central Asia wins: nonstop or one-stop via CX avoids Gulf advisory.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: ams.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct via Central Asia",
  carrier_notes: "Cathay Pacific (CX) / KLM (KL) · nonstop or via LHR",
  path_geojson: line.([[hkg.lng, hkg.lat], [80.0, 44.0], [45.0, 46.0], [ams.lng, ams.lat]]),
  distance_km: 9400, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best option for HKG→AMS. Central Asian corridor avoids Gulf advisory zone on both ends. No hub connection risk.",
  ranking_context: "Ranks first: avoids advisory zone on both legs. KLM and CX combined provide solid rebooking options on this corridor.",
  watch_for: "Central Asian corridor has peripheral level-1 advisory proximity. Verify Eurocontrol ATFM status for any flow management restrictions.",
  explanation_bullets: [
    "HKG→AMS via Central Asian corridor tracks northwest — no Gulf or Middle East airspace transit.",
    "KLM and Cathay Pacific codeshare services provide daily frequency with rebooking depth.",
    "Central Asian corridor exposure is peripheral — route does not transit any active advisory zone."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily HKG–DXB, multiple DXB–AMS departures",
  path_geojson: line.([[hkg.lng, hkg.lat], [72.0, 21.0], [dxb.lng, dxb.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 11800, typical_duration_minutes: 920, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates. HKG→DXB is clean; DXB→AMS crosses the active advisory zone.",
  ranking_context: "Ranked below the direct option due to advisory exposure on DXB→AMS. Emirates' DXB hub provides the deepest rebooking pool of any Gulf option.",
  watch_for: "DXB→AMS transits the active Middle East advisory zone. Monitor regional escalation if routing via the Gulf.",
  explanation_bullets: [
    "HKG→DXB first leg is clean. Advisory zone exposure is on the DXB→AMS second leg only.",
    "Emirates operates 4 daily HKG→DXB departures — strong day-of rebooking options.",
    "Total journey approximately 2.5 hours longer than the direct option including connection time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: ams.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 2 daily HKG–DOH–AMS",
  path_geojson: line.([[hkg.lng, hkg.lat], [72.0, 21.0], [doh.lng, doh.lat], [28.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 11600, typical_duration_minutes: 905, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' HKG–AMS via Doha. Same advisory exposure as Dubai on DOH→AMS — carrier preference decides.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→AMS and DXB→AMS carry identical advisory zone exposure.",
  watch_for: "DOH→AMS transits the active advisory zone. Identical exposure profile to the Dubai option.",
  explanation_bullets: [
    "HKG→DOH first leg is clean. Advisory zone exposure is on the DOH→AMS second leg.",
    "Qatar Airways operates 2 daily HKG→DOH services with AMS connections.",
    "Same advisory risk profile as the Dubai option — choose based on carrier preference."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Amsterdam (3 corridor families: central_asia, gulf_dubai, gulf_doha) — central_asia ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# TOKYO → LONDON
# Three families: central_asia (direct BA/JAL) · Gulf Dubai · Gulf Doha
# Central Asia wins: Russia-avoidance routing keeps both ends clear of advisory.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct via Central Asia",
  carrier_notes: "British Airways (BA) / Japan Airlines (JL) · nonstop NRT–LHR",
  path_geojson: line.([[nrt.lng, nrt.lat], [95.0, 50.0], [55.0, 48.0], [15.0, 47.0], [lhr.lng, lhr.lat]]),
  distance_km: 9570, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for NRT→LHR. Nonstop via Central Asian corridor avoids Gulf advisory zone on both legs. Russia-avoidance adds time but keeps the route clear of high-intensity conflict zones.",
  ranking_context: "Ranks first: avoids advisory zone on both ends. BA and JAL codeshare gives solid rebooking depth. Gulf options both carry advisory zone exposure on the second leg.",
  watch_for: "NRT→LHR via Central Asian corridor tracks south of Russia — check Eurocontrol ATFM for any restrictions on departure day.",
  explanation_bullets: [
    "NRT→LHR nonstop routes via Central Asian airspace, avoiding Russian FIR and Gulf advisory zones on both legs.",
    "British Airways and Japan Airlines operate daily nonstop NRT–LHR services — combined frequency provides rebooking depth.",
    "Post-2022 Russia avoidance adds approximately 2 hours vs. pre-closure schedules, but routing is now stable."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily NRT–DXB, 4 daily DXB–LHR",
  path_geojson: line.([[nrt.lng, nrt.lat], [100.0, 25.0], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 12200, typical_duration_minutes: 935, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Emirates alternative via Dubai. NRT→DXB first leg is clean; DXB→LHR crosses the active advisory zone. Strong DXB rebooking depth.",
  ranking_context: "Ranked below the direct option due to advisory zone exposure on DXB→LHR. Use when nonstop availability is limited or Emirates' DXB frequency gives better day-of rebooking.",
  watch_for: "DXB→LHR transits the active Middle East advisory zone. Emirates operates 2 daily NRT–DXB with strong LHR onward connections.",
  explanation_bullets: [
    "NRT→DXB first leg routes south via South Asian airspace — clean, no advisory zone exposure.",
    "Emirates operates 2 daily NRT→DXB departures with 4 daily DXB→LHR connections — solid recovery options.",
    "Advisory zone exposure is entirely on the DXB→LHR second leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: lhr.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 2 daily NRT–DOH–LHR",
  path_geojson: line.([[nrt.lng, nrt.lat], [100.0, 25.0], [doh.lng, doh.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 12000, typical_duration_minutes: 920, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' NRT–LHR via Doha. Same advisory exposure as Dubai on the DOH→LHR leg — choose on carrier preference.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→LHR carries identical advisory zone exposure to DXB→LHR.",
  watch_for: "DOH→LHR transits the active advisory zone. QR maintains full Doha hub operations.",
  explanation_bullets: [
    "NRT→DOH first leg routes through South Asian airspace — clean, no advisory exposure.",
    "Qatar Airways operates 2 daily NRT→DOH services with LHR connections.",
    "Same advisory risk profile as the Dubai option — route choice is carrier preference."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: lhr.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · 2 daily ICN–LHR, 10+ daily NRT–ICN",
  path_geojson: line.([[nrt.lng, nrt.lat], [icn.lng, icn.lat], [60.0, 44.0], [lhr.lng, lhr.lat]]),
  distance_km: 9900, typical_duration_minutes: 775, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Korean Air's NRT→LHR option via Incheon. ICN sits naturally westward from Tokyo on the path to Europe — minimal geometric deviation. ICN hub is world-class (0/3); ICN→LHR uses Central Asian corridor with a natural hub recovery point.",
  ranking_context: "Ranks below the direct option because the connection adds hub risk vs. BA/JAL's nonstop service. Ranks well above Gulf options because both legs avoid the advisory zone. Best used when nonstop availability is limited or Korean Air fares are compelling.",
  watch_for: "ICN→LHR uses the Central Asian corridor. Check ATFM restrictions before departure. NRT→ICN over East Sea airspace is clean and uncongested.",
  explanation_bullets: [
    "NRT→ICN is a short first leg (~1.5 hours) over clean East Sea airspace — no advisory concerns.",
    "ICN hub rated 0/3 (world-class) with multiple daily ICN→LHR frequencies via Korean Air.",
    "ICN→LHR uses the Central Asian corridor westbound — same routing constraint as the direct BA/JAL nonstop.",
    "Neither leg touches the Middle East advisory zone — this routing is fully Gulf-free.",
    "Total journey approximately 13 hours including layover. Use this when direct availability is sold out or Korean Air positioning suits your itinerary."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → London (4 corridor families: central_asia, gulf_dubai, gulf_doha, north_asia_icn/Seoul)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → LONDON
# Three families: south_asia_direct (BA/AI nonstop) · Gulf Dubai · Gulf Doha
# South Asia Direct wins: nonstop avoids Gulf hub dependency.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "south_asia_direct",
  route_name: "Direct",
  carrier_notes: "British Airways (BA) / Air India (AI) · daily nonstop DEL–LHR",
  path_geojson: line.([[del.lng, del.lat], [55.0, 33.0], [25.0, 42.0], [lhr.lng, lhr.lat]]),
  distance_km: 6720, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for DEL→LHR. Nonstop direct flight avoids Gulf hub dependency. BA and Air India provide strong combined daily frequency.",
  ranking_context: "Ranks first: no hub connection risk, avoids Gulf advisory zone on both ends. Fastest journey of any option on this pair.",
  watch_for: "DEL→LHR routes near the Iranian and Pakistani FIR boundaries. Peripheral advisory proximity but route does not transit any active advisory zone.",
  explanation_bullets: [
    "British Airways and Air India both operate daily nonstop DEL–LHR services — the deepest rebooking pool on this corridor.",
    "Nonstop routing eliminates connection risk at a Gulf hub and keeps both ends of the journey clear of the advisory zone.",
    "At 9 hours, the direct flight is approximately 2–3 hours faster than Gulf hub options."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Fly Dubai (FZ) · multiple daily DEL–DXB, 4 daily DXB–LHR",
  path_geojson: line.([[del.lng, del.lat], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 7900, typical_duration_minutes: 750, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates' DXB hub. DEL→DXB first leg is clean; DXB→LHR crosses the active advisory zone.",
  ranking_context: "Ranked below the direct option due to advisory zone exposure on DXB→LHR. Use when direct availability is limited — DXB has the deepest rebooking pool.",
  watch_for: "DXB→LHR transits the active Middle East advisory zone. Emirates + flydubai combined frequency on DEL–DXB is very high.",
  explanation_bullets: [
    "DEL→DXB first leg is clean. Advisory zone exposure is entirely on the DXB→LHR second leg.",
    "Emirates and flydubai combined operate 8+ daily DEL→DXB departures — strongest rebooking depth of any DEL-based corridor.",
    "Total journey is 2–3 hours longer than the direct option including connection time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: lhr.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily DEL–DOH–LHR",
  path_geojson: line.([[del.lng, del.lat], [doh.lng, doh.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 7700, typical_duration_minutes: 735, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' DEL–LHR via Doha. Same advisory exposure as Dubai on DOH→LHR — choose on carrier preference.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→LHR carries the same advisory zone exposure as DXB→LHR.",
  watch_for: "DOH→LHR transits the active advisory zone. QR operates 3 daily DEL→DOH departures — solid frequency.",
  explanation_bullets: [
    "DEL→DOH first leg is clean. Advisory zone exposure is on the DOH→LHR second leg.",
    "Qatar Airways operates 3 daily DEL→DOH services with strong LHR connections.",
    "Same advisory risk profile as the Dubai option — no meaningful disruption-profile difference."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → London (3 corridor families: south_asia_direct, gulf_dubai, gulf_doha) — direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI → LONDON
# Three families: south_asia_direct (BA/AI nonstop) · Gulf Dubai · Gulf Doha
# South Asia Direct wins: nonstop keeps both ends clear of advisory.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "south_asia_direct",
  route_name: "Direct",
  carrier_notes: "British Airways (BA) / Air India (AI) · daily nonstop BOM–LHR",
  path_geojson: line.([[bom.lng, bom.lat], [52.0, 30.0], [22.0, 42.0], [lhr.lng, lhr.lat]]),
  distance_km: 7220, typical_duration_minutes: 575, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for BOM→LHR. Nonstop direct flight avoids Gulf hub dependency. BA and Air India provide strong combined frequency.",
  ranking_context: "Ranks first: no hub connection risk, avoids Gulf advisory zone on both ends. Fastest option on this pair.",
  watch_for: "BOM→LHR routes near Iranian FIR boundaries — peripheral level-1 exposure, no active advisory zone transit.",
  explanation_bullets: [
    "British Airways and Air India both operate daily nonstop BOM–LHR services — strong combined rebooking depth.",
    "Nonstop eliminates connection risk at a Gulf hub and keeps both legs clear of the advisory zone.",
    "Approximately 2–3 hours faster than Gulf hub options including connection time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) / Air India (AI) via DXB · multiple daily BOM–DXB, 4 daily DXB–LHR",
  path_geojson: line.([[bom.lng, bom.lat], [dxb.lng, dxb.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 8400, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Dubai. BOM→DXB first leg is clean; DXB→LHR crosses the active advisory zone.",
  ranking_context: "Ranked below the direct option due to advisory zone exposure on DXB→LHR. Emirates has the highest frequency and strongest hub depth on this corridor.",
  watch_for: "DXB→LHR transits the active Middle East advisory zone. Emirates + AI combined frequency on BOM–DXB is very high.",
  explanation_bullets: [
    "BOM→DXB first leg is clean. Advisory zone exposure is entirely on the DXB→LHR second leg.",
    "Emirates and Air India combined operate 6+ daily BOM→DXB departures — strong rebooking depth.",
    "Total journey approximately 2–3 hours longer than nonstop including connection time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: lhr.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily BOM–DOH–LHR",
  path_geojson: line.([[bom.lng, bom.lat], [doh.lng, doh.lat], [38.0, 33.0], [lhr.lng, lhr.lat]]),
  distance_km: 8100, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' BOM–LHR via Doha. Same advisory exposure as Dubai on DOH→LHR — choose on carrier preference.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→LHR carries the same advisory zone exposure as DXB→LHR.",
  watch_for: "DOH→LHR transits the active advisory zone. QR operates 3 daily BOM→DOH services.",
  explanation_bullets: [
    "BOM→DOH first leg is clean. Advisory zone exposure is on the DOH→LHR second leg.",
    "Qatar Airways operates 3 daily BOM→DOH services with strong LHR connections.",
    "Same advisory risk profile as the Dubai option — no meaningful disruption-profile difference."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → London (3 corridor families: south_asia_direct, gulf_dubai, gulf_doha) — direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → PARIS
# Three families: direct (SIA/AF) · Gulf Dubai · Gulf Doha
# Direct wins: nonstop or via Central Asian corridor avoids Gulf advisory.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: cdg.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Singapore Airlines Direct",
  carrier_notes: "Singapore Airlines (SQ) / Air France (AF) · SIN–CDG nonstop",
  path_geojson: line.([[sin.lng, sin.lat], [75.0, 15.0], [52.0, 35.0], [25.0, 44.0], [cdg.lng, cdg.lat]]),
  distance_km: 10730, typical_duration_minutes: 800, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best option for SIN→CDG. Singapore Airlines' nonstop avoids Gulf airspace entirely. No connection risk at an intermediate hub.",
  ranking_context: "Ranks first: only option that avoids the advisory zone on both ends. No hub dependency. SIA direct has lower structural score than the Gulf alternatives but wins on airspace profile.",
  watch_for: "SIN→CDG routes via Central Asian corridor — monitor Eurocontrol ATFM for any flow restrictions on departure day. SQ is the only nonstop carrier so direct rebooking options are limited.",
  explanation_bullets: [
    "Singapore Airlines operates a direct SIN–CDG service tracking northwest via South Asia and the Central Asian corridor — no Gulf or Middle East airspace transit.",
    "No hub connection means no missed connection risk, no layover, no intermediate hub vulnerability.",
    "If the direct service is disrupted, fallback routes all involve Gulf hub advisory zone exposure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily SIN–DXB, multiple DXB–CDG departures",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [dxb.lng, dxb.lat], [32.0, 38.0], [cdg.lng, cdg.lat]]),
  distance_km: 11900, typical_duration_minutes: 920, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates. SIN→DXB first leg is clean; DXB→CDG crosses the active advisory zone.",
  ranking_context: "Ranked below the direct option due to advisory zone exposure on DXB→CDG. Best fallback when SQ direct is unavailable — Emirates has the strongest SIN–DXB frequency.",
  watch_for: "DXB→CDG transits the active Middle East advisory zone. Emirates operates 4 daily SIN→DXB departures — strong first-leg rebooking options.",
  explanation_bullets: [
    "SIN→DXB first leg routes through South Asian airspace — no advisory exposure.",
    "Emirates provides the highest SIN–DXB frequency — strong day-of rebooking if departure is disrupted.",
    "Advisory zone exposure is entirely on the DXB→CDG second leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: cdg.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 3 daily SIN–DOH–CDG",
  path_geojson: line.([[sin.lng, sin.lat], [85.0, 12.0], [doh.lng, doh.lat], [32.0, 38.0], [cdg.lng, cdg.lat]]),
  distance_km: 11600, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Qatar Airways' SIN–CDG via Doha. Same advisory zone exposure as Dubai on the DOH→CDG leg — choose on carrier preference.",
  ranking_context: "Scores identically to Dubai (composite 63, :watchful). DOH→CDG carries the same advisory zone exposure as DXB→CDG.",
  watch_for: "DOH→CDG transits the active advisory zone. QR operates 3 daily SIN→DOH services with CDG connections.",
  explanation_bullets: [
    "SIN→DOH first leg is clean. Advisory zone exposure is on the DOH→CDG second leg.",
    "Qatar Airways operates 3 daily SIN→DOH services with CDG connections — strong combined frequency.",
    "Same advisory risk profile as the Dubai option — no meaningful disruption-profile difference."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Paris (3 corridor families: direct, gulf_dubai, gulf_doha) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → TOKYO
# Three families: direct · north_asia_hkg · north_asia_icn
# All three avoid advisory zones — this pair is a stable, clean corridor.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Singapore Airlines (SQ) · 1 daily SIN–NRT; ANA · 1 daily SIN–NRT; Japan Airlines (JL) · 1 daily SIN–HND",
  path_geojson: line.([[sin.lng, sin.lat], [110.0, 15.0], [125.0, 28.0], [nrt.lng, nrt.lat]]),
  distance_km: 5310, typical_duration_minutes: 390, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for SIN→TYO. Direct routing through South China Sea and Philippine airspace — no active advisory zone on either leg. Singapore Airlines, ANA, and JAL all operate direct services.",
  ranking_context: "Ranks highest because the direct routing is clean on all dimensions: no advisory exposure, no connection risk, and three carriers providing meaningful schedule depth.",
  watch_for: "SIN–NRT direct is clean under current conditions. Weather disruption at NRT in typhoon season (July–September) is the most likely schedule risk.",
  explanation_bullets: [
    "SIN→NRT/HND routes through South China Sea and Philippine airspace — no active advisory zone on either leg.",
    "Three carriers (SQ, ANA, JL) operate direct services, providing meaningful schedule alternatives if one departure is disrupted.",
    "Journey time is approximately 6.5 hours — one of the shorter long-haul segments, with high schedule reliability historically.",
    "No connection point means rebooking is simpler: one airline, one leg, one failure mode to manage.",
    "If NRT is affected by typhoon disruption, HND provides a nearby alternative served by JAL on this same corridor."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · 3 daily SIN–HKG–NRT",
  path_geojson: line.([[sin.lng, sin.lat], [hkg.lng, hkg.lat], [nrt.lng, nrt.lat]]),
  distance_km: 5820, typical_duration_minutes: 450, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean one-stop option via Hong Kong. Both legs avoid advisory zones. Strong choice if direct flights are sold out or if Cathay Pacific connectivity is preferred.",
  ranking_context: "Same clean airspace profile as direct, but adds a connection point and extra journey time. Ranked below direct because the connection introduces schedule risk with no airspace benefit.",
  watch_for: "HKG is a consistently high-performing hub. The added connection time (approximately 1 hour) means slight exposure to missed connections if the SIN–HKG leg is delayed.",
  explanation_bullets: [
    "SIN→HKG routes through South China Sea — clean segment with no advisory zones.",
    "HKG→NRT routes through Pacific airspace, also clean. This pair avoids all current active advisory zones on both legs.",
    "Cathay Pacific offers strong SIN–HKG frequency (3+ daily) providing good rescheduling options.",
    "Hong Kong (HKG) is one of the world's most operationally reliable connection hubs for Asia–Pacific routing.",
    "Adds approximately 60 minutes versus direct due to the connection geometry — worth it only if direct availability is limited."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: nrt.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · 2 daily SIN–ICN–NRT; Asiana (OZ) · 1 daily SIN–ICN–NRT",
  path_geojson: line.([[sin.lng, sin.lat], [108.0, 18.0], [icn.lng, icn.lat], [nrt.lng, nrt.lat]]),
  distance_km: 5980, typical_duration_minutes: 470, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Second one-stop option via Seoul. Clean airspace on both segments. Korean Air and Asiana both serve this connection.",
  ranking_context: "Same clean airspace as the HKG option, but ICN is a slightly lower-resilience hub for South Asian connections than HKG. Ranks below HKG on hub quality.",
  watch_for: "ICN hub is operationally strong. The SIN–ICN leg is clean. Korean Air and Asiana provide two different carriers at the same hub, which is useful for rescheduling.",
  explanation_bullets: [
    "SIN→ICN routes north through South China Sea and Philippine Sea — no active advisory exposure.",
    "ICN→NRT is a very short hop (~2 hours). Schedule reliability on this leg is high.",
    "Two carriers (KE, OZ) at ICN provide carrier flexibility when rebooking if disruption occurs.",
    "Incheon (ICN) is a large, efficient hub with good connectivity across Northeast Asia.",
    "Total journey is approximately 7.5–8 hours, slightly longer than the HKG option due to Seoul's more northerly position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Tokyo (3 corridor families: direct, HKG, ICN) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → LONDON
# Three families: central_asia (direct) · north_asia_hkg · gulf_dubai
# Reverse of London → Seoul, but departure point changes scoring context.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Korean Air (KE) · 1 daily ICN–LHR via Central Asian corridor",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 45.0], [65.0, 48.0], [40.0, 48.0], [lhr.lng, lhr.lat]]),
  distance_km: 9120, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Most direct option on this corridor. Korean Air's ICN–LHR service routes via the Central Asian corridor — one level-1 advisory segment, but no Gulf exposure.",
  ranking_context: "Ranks above Dubai because it avoids the active Middle East advisory zone entirely. The Central Asian corridor carries a level-1 advisory (below the active zone threshold), and direct routing eliminates connection risk.",
  watch_for: "The Central Asian corridor (Kazakhstan/Caspian region) carries a persistent level-1 advisory. Check KE NOTAM status within 48 hours if planning around this route.",
  explanation_bullets: [
    "ICN→LHR direct routes west via Central Asian airspace — level-1 advisory (near zone, not through it). No transit of the active Middle East advisory zone.",
    "Korean Air is the sole direct carrier on this city pair, which means fewer rebooking options if the flight is disrupted.",
    "Direct routing eliminates the largest risk on this corridor: a missed connection at a Gulf hub during a period of regional tension.",
    "Journey time is approximately 11 hours — consistent and well-established since 2023 rerouting settled.",
    "If Korean Air cancels or you miss this flight, options are limited on the same day: connecting via HKG or IST adds significant journey time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: lhr.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · 3 daily ICN–HKG–LHR",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat], [65.0, 40.0], [lhr.lng, lhr.lat]]),
  distance_km: 9760, typical_duration_minutes: 710, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Second viable option via Cathay's Hong Kong hub. ICN–HKG is clean; HKG–LHR uses the Central Asian corridor. Best rebooking depth of the non-Gulf options.",
  ranking_context: "Slightly lower structural score than direct due to the connection point, but better operational depth (Cathay frequency vs Korean Air single daily). Ranks ahead of Dubai due to airspace preference.",
  watch_for: "HKG–LHR uses the Central Asian corridor for its westbound routing. Check Cathay NOTAM status for the LHR segment if Central Asian flow restrictions are active.",
  explanation_bullets: [
    "ICN→HKG first leg is clean — South China Sea airspace, no advisory zones.",
    "HKG→LHR routes via the Central Asian corridor — level-1 advisory, same as the direct Korean Air option, but no Gulf exposure.",
    "Cathay Pacific offers 3+ daily ICN–HKG departures, the highest frequency of any carrier on the ICN–HKG segment.",
    "Hong Kong (HKG) is one of the most resilient hubs for UK-bound connections in Asia.",
    "Adding a connection adds schedule risk but improves carrier options significantly versus Korean Air direct."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · ICN–DXB–LHR, 2 daily ICN–DXB departures",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 30.0], [dxb.lng, dxb.lat], [32.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 11200, typical_duration_minutes: 790, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. ICN→DXB is clean; DXB→LHR crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below both Central Asian options due to DXB→LHR advisory zone exposure. Emirates' frequency is an advantage, but the airspace risk on the second leg is real.",
  watch_for: "DXB→LHR transits the active Middle East advisory zone. Emirates operates this route daily with good rebooking options at DXB, but the advisory zone exposure is the key differentiator versus Central Asian routing.",
  explanation_bullets: [
    "ICN→DXB first leg routes south through Southeast Asia and Indian Ocean — no active advisory zone.",
    "DXB→LHR second leg crosses the active Middle East advisory zone. This is the primary risk on this routing.",
    "Emirates provides 2 daily ICN–DXB departures, which is better frequency than Korean Air direct — a meaningful rebooking advantage.",
    "Dubai (DXB) has operated without airspace closure throughout the current conflict period, but regional escalation could affect hub access at short notice.",
    "Total journey adds approximately 2 hours versus the direct option due to the southerly Gulf routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → London (3 corridor families: central_asia, HKG, gulf_dubai) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# TOKYO → AMSTERDAM
# Three families: north_asia_icn (Via Seoul) · central_asia (Direct, KLM) · gulf_dubai
# Reverse of Amsterdam → Tokyo; scoring reflects NRT departure context.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: ams.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · 3 daily NRT–ICN–AMS; Asiana (OZ) · 1 daily NRT–ICN–AMS",
  path_geojson: line.([[nrt.lng, nrt.lat], [icn.lng, icn.lat], [65.0, 48.0], [35.0, 50.0], [ams.lng, ams.lat]]),
  distance_km: 9410, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Highest-frequency option for NRT→AMS. Korean Air and Asiana both serve this connection with strong schedule depth. ICN–AMS leg uses the Central Asian corridor.",
  ranking_context: "Ranked above Dubai because it avoids the active Middle East advisory zone. Ranked slightly below direct because of the connection point, but the NRT–ICN–AMS frequency is substantially better than KLM direct.",
  watch_for: "ICN–AMS segment uses the Central Asian corridor. Check departure status if Eurocontrol flow restrictions are active on Central Asian routes.",
  explanation_bullets: [
    "NRT→ICN first leg is clean — short Pacific/East Sea hop with no advisory zones.",
    "ICN→AMS routes west via Central Asian corridor — level-1 advisory but no Gulf exposure or active advisory zone transit.",
    "Korean Air operates 3 daily NRT–ICN departures — strong frequency and multiple rebooking windows.",
    "Adding Seoul as a connection point introduces schedule risk but substantially improves onward frequency versus KLM direct.",
    "Incheon (ICN) is an operationally strong hub with good European connectivity."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: ams.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "KLM (KL) · 1 daily NRT–AMS via Central Asian/polar routing",
  path_geojson: line.([[nrt.lng, nrt.lat], [150.0, 60.0], [90.0, 60.0], [50.0, 58.0], [ams.lng, ams.lat]]),
  distance_km: 9350, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "KLM's direct NRT–AMS service. No connection point, avoids Gulf entirely. The northerly routing avoids the Middle East advisory zone but uses a single-carrier, single-flight option.",
  ranking_context: "Ranks close to the Seoul option — direct routing eliminates connection risk, but single-carrier and limited daily frequency reduce rebooking depth if disruption occurs.",
  watch_for: "KLM operates a single daily NRT–AMS departure. If this flight is disrupted, same-day alternatives require connecting via ICN or DXB, adding substantial journey time.",
  explanation_bullets: [
    "NRT–AMS direct routes via northern Pacific and Central Asian airspace — level-1 advisory segment but no Gulf exposure or active zone transit.",
    "No connection point means no missed-connection risk — the main structural advantage over the Seoul option.",
    "KLM operates once daily on this route, which limits rebooking options if the outbound is disrupted.",
    "Northern routing (via polar/Central Asian airspace) is longer in distance but consistently reliable under current conditions.",
    "If the KLM departure is cancelled, connecting via ICN or DXB is the most practical same-day fallback."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily NRT–DXB–AMS",
  path_geojson: line.([[nrt.lng, nrt.lat], [110.0, 20.0], [dxb.lng, dxb.lat], [32.0, 38.0], [ams.lng, ams.lat]]),
  distance_km: 12400, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates option via Dubai. High frequency and rebooking depth, but DXB–AMS crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below both Central Asian options due to DXB→AMS advisory zone exposure on the second leg. Emirates' frequency is an advantage for rebooking, but the airspace risk differentiates this option.",
  watch_for: "DXB→AMS transits the active Middle East advisory zone. Emirates provides 2 daily NRT–DXB departures — strong rebooking options at DXB itself.",
  explanation_bullets: [
    "NRT→DXB first leg routes south via Southeast Asia and Indian Ocean — no advisory zones.",
    "DXB→AMS second leg crosses the active Middle East advisory zone. This is the key risk factor distinguishing this option from the Central Asian alternatives.",
    "Emirates provides strong NRT–DXB frequency (2 daily), making it the best rebooking fallback if other options are disrupted.",
    "Dubai (DXB) has maintained full operations throughout current regional tensions, but advisory zone exposure on DXB–AMS remains a real risk.",
    "Total journey is approximately 2–3 hours longer than the Central Asian options due to the southerly routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Amsterdam (3 corridor families: ICN, central_asia, gulf_dubai) — Seoul ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → FRANKFURT
# Three families: central_asia (direct) · turkey_hub · gulf_dubai
# Reverse of Frankfurt → Hong Kong; HKG departure shifts routing geometry.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: fra.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Cathay Pacific (CX) · 1 daily HKG–FRA; Lufthansa (LH) · 1 daily HKG–FRA",
  path_geojson: line.([[hkg.lng, hkg.lat], [85.0, 43.0], [52.0, 46.0], [fra.lng, fra.lat]]),
  distance_km: 9200, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for HKG→FRA. Direct routing via Central Asian corridor — level-1 advisory but avoids the active Middle East advisory zone entirely. Both Cathay Pacific and Lufthansa operate this service.",
  ranking_context: "Ranks above Gulf options because it avoids the active Middle East advisory zone. Two carriers provide some schedule alternatives, though both operate once daily.",
  watch_for: "HKG–FRA uses the Central Asian corridor. Check Eurocontrol flow restriction status if departing during high-traffic periods — Central Asian corridor congestion is the primary delay risk.",
  explanation_bullets: [
    "HKG→FRA routes west via the Central Asian corridor — level-1 advisory (near zone, not through it). No transit of the active Middle East advisory zone.",
    "Both Cathay Pacific and Lufthansa operate direct HKG–FRA services, providing carrier flexibility on this route.",
    "Direct routing eliminates connection risk — a meaningful advantage on a 11-hour flight where missed connections are costly.",
    "The Central Asian corridor is the only non-Gulf path for HKG→Europe. If Eurocontrol applies flow restrictions, expect 30–60 minute delays.",
    "Journey time of approximately 11 hours is well-established and consistent since 2023 rerouting settled."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: fra.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 3 daily HKG–IST–FRA; Cathay Pacific (CX) codeshare",
  path_geojson: line.([[hkg.lng, hkg.lat], [85.0, 43.0], [ist.lng, ist.lat], [fra.lng, fra.lat]]),
  distance_km: 9800, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Second clean-airspace option via Istanbul. HKG–IST uses the Central Asian corridor; IST–FRA is clean. Turkish Airlines offers the highest frequency on this connection.",
  ranking_context: "Ranked below direct due to the connection point and Istanbul hub's geographic proximity to the conflict zone. But Turkish Airlines' frequency is substantially better than either direct carrier.",
  watch_for: "HKG–IST uses the Central Asian corridor. Istanbul sits within regional monitoring range of the conflict zone. Check TK operational status if regional tensions escalate.",
  explanation_bullets: [
    "HKG→IST first leg uses the Central Asian corridor — level-1 advisory, same as the direct routing but with a connection point added.",
    "IST→FRA second leg is clean — well-established European routing with no advisory zones.",
    "Turkish Airlines provides 3+ daily HKG–IST departures, offering the best frequency on this segment of any carrier.",
    "Istanbul (IST) hub sits ~900km from the Ukrainian conflict zone — within monitoring range but has maintained full operations.",
    "The connection adds approximately 1 hour versus direct but significantly improves same-day rebooking options."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily HKG–DXB–FRA; Lufthansa (LH) codeshare",
  path_geojson: line.([[hkg.lng, hkg.lat], [100.0, 15.0], [dxb.lng, dxb.lat], [32.0, 38.0], [fra.lng, fra.lat]]),
  distance_km: 11000, typical_duration_minutes: 800, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency alternative via Emirates. HKG→DXB first leg is clean; DXB→FRA crosses the active Middle East advisory zone.",
  ranking_context: "Ranked below Central Asian options due to advisory zone exposure on DXB→FRA. Emirates' frequency advantage is real, but the airspace risk on the second leg is the key differentiator.",
  watch_for: "DXB→FRA transits the active Middle East advisory zone. Emirates operates 4 daily HKG–DXB departures — the strongest rebooking depth of any option on this pair.",
  explanation_bullets: [
    "HKG→DXB first leg routes southwest through South Asian airspace — no advisory exposure.",
    "DXB→FRA second leg crosses the active Middle East advisory zone. This is the primary risk on this routing.",
    "Emirates provides 4 daily HKG–DXB departures — the best first-leg frequency of any option on this pair.",
    "Dubai (DXB) has maintained full operations throughout the conflict period, but DXB–FRA advisory zone exposure is real and documented.",
    "Total journey adds approximately 90 minutes versus direct due to the more southerly routing geometry through the Gulf."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Frankfurt (3 corridor families: central_asia, IST, gulf_dubai) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → AMSTERDAM
# Three families: direct (central_asia) · turkey_hub · gulf_dubai
# Reverse of Amsterdam → Delhi; DEL departure means slightly different airspace profile.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: ams.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air India (AI) · 1 daily DEL–AMS; KLM (KL) · 1 daily DEL–AMS",
  path_geojson: line.([[del.lng, del.lat], [55.0, 38.0], [35.0, 45.0], [20.0, 50.0], [ams.lng, ams.lat]]),
  distance_km: 6790, typical_duration_minutes: 490, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for DEL→AMS. Air India and KLM both operate direct services, routing via Iranian/Central Asian airspace. Level-1 advisory on the Iran segment but no Gulf exposure.",
  ranking_context: "Ranks above Gulf options because direct routing avoids the active Middle East advisory zone. The Iran FIR segment carries a level-1 advisory but has not affected operational routing as of last review.",
  watch_for: "DEL–AMS direct routes over Iran (FIR: OIIX). Iranian airspace carries a persistent level-1 advisory. Sudden restriction of Iranian FIR would require rerouting, adding approximately 45–90 minutes.",
  explanation_bullets: [
    "DEL→AMS direct routes west via Afghanistan/Iran FIR and then through Caucasus/Eastern European airspace.",
    "Iranian FIR carries a level-1 advisory — not the active high-severity zone, but worth monitoring for escalation.",
    "Both Air India and KLM operate direct services, providing carrier flexibility despite limited combined daily frequency.",
    "No connection point eliminates the primary delay multiplier on this route — important for a 8-hour journey.",
    "If Iranian FIR restrictions tighten, airlines typically reroute south via Oman/Saudi Arabia, adding 45–90 minutes to the journey."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: ams.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 4 daily DEL–IST–AMS",
  path_geojson: line.([[del.lng, del.lat], [55.0, 35.0], [ist.lng, ist.lat], [ams.lng, ams.lat]]),
  distance_km: 7440, typical_duration_minutes: 560, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Second clean-airspace option via Turkish Airlines. DEL–IST routes via Iran/Central Asia (level-1 advisory); IST–AMS is clean European routing. Best frequency of the non-Gulf options.",
  ranking_context: "Ranked below direct due to connection point but above Dubai due to airspace preference. Turkish Airlines' high frequency significantly improves schedule flexibility.",
  watch_for: "DEL–IST segment routes over Iran/Afghanistan — level-1 advisory zone. Istanbul sits within regional monitoring range. Combined frequency is the strongest advantage of this option.",
  explanation_bullets: [
    "DEL→IST first leg routes via Afghanistan and Iran FIR — level-1 advisory, same airspace risk as the direct option but with a connection point added.",
    "IST→AMS second leg is clean European routing — no advisory zones.",
    "Turkish Airlines operates 4 daily DEL–IST departures, providing the highest frequency on the DEL–Europe segment of any carrier.",
    "Istanbul hub is within monitoring range of regional tensions but has maintained full operations throughout.",
    "The connection adds approximately 1 hour versus direct but greatly improves same-day rebooking options."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 4 daily DEL–DXB–AMS; flydubai (FZ) codeshare",
  path_geojson: line.([[del.lng, del.lat], [65.0, 23.0], [dxb.lng, dxb.lat], [32.0, 38.0], [ams.lng, ams.lat]]),
  distance_km: 8600, typical_duration_minutes: 640, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency option via Emirates. DEL→DXB first leg is clean; DXB→AMS crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below Central Asian options due to DXB→AMS advisory zone exposure. Emirates' strong DEL–DXB frequency makes this the best rebooking fallback if direct services are unavailable.",
  watch_for: "DXB→AMS transits the active Middle East advisory zone. Emirates provides 4 daily DEL–DXB departures — strongest first-leg frequency of any option on this pair.",
  explanation_bullets: [
    "DEL→DXB first leg routes southwest via Pakistan/Arabian Sea — clean segment with no advisory zones.",
    "DXB→AMS second leg crosses the active Middle East advisory zone. This is the primary risk differentiating this option from Central Asian routing.",
    "Emirates provides 4 daily DEL–DXB departures — the best rebooking frequency of any option on this pair.",
    "Dubai (DXB) has maintained full operations throughout the conflict period. The advisory zone exposure is on the DXB–AMS leg, not at the hub itself.",
    "Journey adds approximately 90 minutes versus direct due to the southerly Gulf routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Amsterdam (3 corridor families: central_asia, IST, gulf_dubai) — Direct ranks first")

# ─────────────────────────────────────────────────────────────────────────────
# SYDNEY → LONDON
# Australia's highest-demand corridor. Three distinct airspace stories:
# SQ via Singapore (clean), QF/BA via Dubai (ME zone), Cathay via HKG (clean, longer)
# Corridor choice genuinely matters here — this is a textbook Pathfinder pair.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: lhr.id, via_hub_city_id: sin.id,
  corridor_family: "direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · 2 daily SYD–SIN–LHR; Qantas (QF) codeshare",
  path_geojson: line.([[syd.lng, syd.lat], [sin.lng, sin.lat], [78.0, 28.0], [48.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 16990, typical_duration_minutes: 1205, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for SYD→LHR. SYD–SIN first leg is completely clean; SIN–LHR uses the Central Asian corridor, which is the standard post-2022 route for European traffic from this hub.",
  ranking_context: "Ranks first because neither leg touches the Middle East advisory zone. SIN hub is one of the world's most resilient — strong rebooking depth. Only downside is total journey time (~20h).",
  watch_for: "SIN–LHR second leg traverses the Central Asian corridor. If Eurocontrol flow restrictions are active, the second leg is vulnerable to delays. Check flight status 24–48h before departure.",
  explanation_bullets: [
    "SYD–SIN (approximately 7.5h) routes southeast of the conflict zones and entirely clear of the Middle East advisory zone.",
    "SIN–LHR second leg uses the Central Asian corridor — the same structural routing used by European carriers. No direct advisory zone transit on this segment.",
    "Singapore Airlines has maintained full SIN–LHR service since 2022 and operates 2 daily departures. Rebooking flexibility is strong.",
    "Singapore Changi (SIN) is consistently rated among the world's top hubs for operational reliability and layover quality.",
    "Total journey averages 20–21 hours including transit. This is the longest common option on this corridor but the cleanest airspace profile."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: lhr.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · 2 daily SYD–HKG–LHR",
  path_geojson: line.([[syd.lng, syd.lat], [hkg.lng, hkg.lat], [85.0, 43.0], [48.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 17600, typical_duration_minutes: 1250, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean airspace on both legs. SYD–HKG is a high-quality regional sector; HKG–LHR uses Central Asian routing. Best choice if you want both segments completely clear of the Middle East zone.",
  ranking_context: "Same clean airspace as the Singapore option but ranked slightly lower — HKG–LHR segment runs through the most congested section of the Central Asian corridor, adding schedule risk on the second leg.",
  watch_for: "HKG–LHR is one of the busiest Central Asian corridor slots. Eurocontrol flow restrictions affect this routing more frequently than Singapore-originating traffic. Check flight status 24h before.",
  explanation_bullets: [
    "SYD–HKG (approximately 9h) is a clean, uncomplicated sector entirely south of any advisory zone.",
    "HKG–LHR second leg routes over Central Asia — standard European routing since the Russian airspace closure, but a heavily congested corridor slot.",
    "Cathay Pacific has maintained consistent SYD–HKG–LHR service. HKG hub has shown strong resilience through the post-2022 period.",
    "Total journey is approximately 22 hours including transit — the longest of the three main corridor options, due to more northerly HKG positioning.",
    "This corridor makes most sense for travellers wanting to avoid all Gulf involvement, or connecting onward from HKG to other East Asian points."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: lhr.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily SYD–DXB–LHR; Qantas (QF) codeshare on some services",
  path_geojson: line.([[syd.lng, syd.lat], [90.0, 5.0], [dxb.lng, dxb.lat], [32.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 17120, typical_duration_minutes: 1220, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Highest name-recognition option on this corridor. Strong Emirates frequency and a premium hub experience, but the DXB–LHR second leg transits the active Middle East advisory zone.",
  ranking_context: "Ranked below Singapore and Hong Kong options due to Middle East advisory zone exposure on the DXB–LHR second leg. Emirates' frequency and operational depth are genuine strengths for rebooking if disruption occurs.",
  watch_for: "The DXB–LHR segment crosses the active Middle East advisory zone. Monitor regional tension levels. Emirates' 2 daily SYD–DXB services provide adequate rebooking options if conditions change.",
  explanation_bullets: [
    "SYD–DXB first leg routes northwest via Indian Ocean — clean segment with no active advisory zone exposure.",
    "DXB–LHR second leg crosses the active Middle East advisory zone. This is the main differentiating risk versus Singapore and Hong Kong options.",
    "Dubai (DXB) has operated without closure or major restriction throughout the conflict period. Hub resilience is strong.",
    "Emirates provides 2 daily SYD–DXB departures plus Qantas codeshares — good rebooking options if disruption forces a change at the hub.",
    "Total journey is approximately 20–21 hours including transit, comparable to the Singapore option but with higher airspace exposure on the second leg."
  ],
  calculated_at: now
})

IO.puts("  ✓ Sydney → London (3 corridor families: via SIN, via HKG, via DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → SYDNEY
# Reverse direction of the Sydney corridor. Same three corridor families,
# same airspace logic — but origin/destination reversed and carrier direction noted.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: syd.id, via_hub_city_id: sin.id,
  corridor_family: "direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · 2 daily LHR–SIN–SYD; Qantas (QF) codeshare",
  path_geojson: line.([[lhr.lng, lhr.lat], [48.0, 38.0], [78.0, 28.0], [sin.lng, sin.lat], [syd.lng, syd.lat]]),
  distance_km: 16990, typical_duration_minutes: 1220, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for LHR→SYD. LHR–SIN first leg uses Central Asian routing; SIN–SYD second leg is entirely clean. No advisory zone transit on either segment.",
  ranking_context: "Ranks first because neither leg touches the Middle East advisory zone. The first leg's Central Asian routing is structurally stable. Singapore offers the strongest rebooking depth of any mid-route hub.",
  watch_for: "LHR–SIN first leg uses the Central Asian corridor — if Eurocontrol flow restrictions are active at departure, this leg is most exposed to delays. Plan extra buffer at Heathrow.",
  explanation_bullets: [
    "LHR–SIN first leg (~13h) routes east via Central Asia — the standard European carrier path since the Russian airspace closure. No advisory zone transit.",
    "SIN–SYD second leg (~8h) is a clean sector south of all active zones. Singapore Airlines operates this as a direct, uncomplicated segment.",
    "Singapore hub provides the best rebooking depth of the three corridor options — SQ operates multiple daily SIN–SYD frequencies.",
    "Changi's transit infrastructure makes this the most comfortable mid-route stop for a 20+ hour journey.",
    "The Central Asian corridor on the outbound first leg is structurally congested but not currently under advisory restrictions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: syd.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily LHR–DXB–SYD; Qantas (QF) codeshare",
  path_geojson: line.([[lhr.lng, lhr.lat], [32.0, 38.0], [dxb.lng, dxb.lat], [90.0, 5.0], [syd.lng, syd.lat]]),
  distance_km: 17120, typical_duration_minutes: 1235, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High name recognition and strong hub frequency, but the LHR–DXB first leg transits the active Middle East advisory zone. Book with awareness of current conditions.",
  ranking_context: "Ranked below the Singapore option due to LHR–DXB advisory zone transit on the first leg. Emirates' frequency makes this the best rebooking option if conditions deteriorate after booking.",
  watch_for: "LHR–DXB first leg crosses the active Middle East advisory zone. The Qantas LHR–Perth–SYD variant avoids this zone entirely but is scheduled separately.",
  explanation_bullets: [
    "LHR–DXB first leg (~7h) transits the active Middle East advisory zone. This is the main differentiating risk factor versus the Singapore option.",
    "DXB–SYD second leg (~14h) routes southeast via Indian Ocean — a clean segment with no advisory exposure.",
    "Emirates provides 2 daily LHR–DXB departures plus Qantas codeshares. Strong frequency makes rebooking more accessible if disruption occurs.",
    "Dubai has maintained uninterrupted hub operations throughout the current conflict period.",
    "Total journey is approximately 21 hours including transit — comparable to Singapore routing, with higher airspace exposure on the outbound leg."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: syd.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · 2 daily LHR–HKG–SYD",
  path_geojson: line.([[lhr.lng, lhr.lat], [48.0, 38.0], [85.0, 43.0], [hkg.lng, hkg.lat], [syd.lng, syd.lat]]),
  distance_km: 17600, typical_duration_minutes: 1265, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Cleanest airspace on both legs if Gulf avoidance is the priority. LHR–HKG via Central Asia; HKG–SYD clean southerly routing. Longest option but zero Gulf involvement.",
  ranking_context: "Same clean airspace category as Singapore routing, ranked slightly lower due to longer journey time and the LHR–HKG leg's position in the most congested Central Asian corridor band.",
  watch_for: "LHR–HKG first leg runs through the most congested section of the Central Asian corridor. Eurocontrol flow restrictions affect outbound Heathrow capacity more frequently on this heading.",
  explanation_bullets: [
    "LHR–HKG first leg (~12h) uses Central Asian routing. Cathay Pacific has maintained consistent service on this route since 2022.",
    "HKG–SYD second leg (~9h) routes southeast via Pacific — clean, uncomplicated sector.",
    "This corridor completely avoids the Middle East advisory zone on both legs. Useful if regional escalation makes Gulf exposure unacceptable.",
    "Total journey is approximately 22–23 hours including transit — the longest of the main three options.",
    "Hong Kong remains a capable long-haul hub. Cathay Pacific has demonstrated reliable LHR–HKG connectivity throughout the post-2022 period."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Sydney (3 corridor families: via SIN, via DXB, via HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# MADRID → SINGAPORE
# A high-demand EU corridor that doesn't get enough Pathfinder coverage.
# Spanish/Iberian market. Turkish Airlines is the key clean-airspace option;
# Gulf carriers dominate frequency but carry advisory zone exposure.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily MAD–IST–SIN",
  path_geojson: line.([[mad.lng, mad.lat], [ist.lng, ist.lat], [68.0, 22.0], [sin.lng, sin.lat]]),
  distance_km: 11650, typical_duration_minutes: 820, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best current option for MAD→SIN. Turkish Airlines via Istanbul avoids the Middle East advisory zone on both legs. Competitive pricing and strong frequency on both segments.",
  ranking_context: "Ranks first because neither leg transits the active Middle East advisory zone. Istanbul sits within regional monitoring range of Ukraine but operates normally. Strong rebooking depth.",
  watch_for: "Turkish domestic political context periodically affects IST operations. Check TK status 48h before departure. IST–SIN second leg routes south of the Central Asian pressure zone.",
  explanation_bullets: [
    "MAD–IST (~4h) routes east across the Mediterranean — no advisory zone transit, clean sector.",
    "IST–SIN (~11h) routes southeast via Turkey's southern coast and Indian subcontinent. No transit through the active Middle East advisory zone.",
    "Turkish Airlines holds 2 daily MAD–IST departures and 2–4 daily IST–SIN services. Rebooking depth is solid.",
    "Istanbul (IST) is ~900km from the Ukrainian conflict zone — within regional monitoring range but operationally unaffected as of last review.",
    "Total journey approximately 14 hours including transit. This is the most direct clean-airspace option for the Madrid–Singapore corridor."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily MAD–DXB–SIN; Iberia (IB) codeshare via EK",
  path_geojson: line.([[mad.lng, mad.lat], [32.0, 37.0], [dxb.lng, dxb.lat], [68.0, 20.0], [sin.lng, sin.lat]]),
  distance_km: 12200, typical_duration_minutes: 875, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High frequency and strong hub infrastructure, but the MAD–DXB leg transits the active Middle East advisory zone. Popular option — book with awareness of current conditions.",
  ranking_context: "Ranked below Istanbul due to advisory zone transit on the outbound MAD–DXB leg. Emirates' superior frequency gives this option the best fallback options if conditions deteriorate.",
  watch_for: "MAD–DXB leg transits the active Middle East advisory zone. DXB–SIN second leg is clean. Monitor regional escalation. Emirates provides 2 daily MAD–DXB services — adequate rebooking access.",
  explanation_bullets: [
    "MAD–DXB first leg (~7h) crosses the active Middle East advisory zone. This is the primary differentiating risk versus the Istanbul option.",
    "DXB–SIN second leg (~7h) routes southeast — clean sector with no active advisory exposure.",
    "Emirates provides 2 daily MAD–DXB departures plus Iberia codeshare options. Best rebooking depth of any option on this pair.",
    "Dubai has operated without closure or significant disruption throughout the current conflict period.",
    "Total journey approximately 14–15 hours including transit — comparable to Istanbul option in flight time, with higher airspace exposure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: sin.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 2 daily MAD–DOH–SIN",
  path_geojson: line.([[mad.lng, mad.lat], [28.0, 36.0], [doh.lng, doh.lat], [68.0, 20.0], [sin.lng, sin.lat]]),
  distance_km: 11900, typical_duration_minutes: 850, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha is a well-run option with strong onward Singapore connectivity, but the MAD–DOH outbound leg crosses the active Middle East advisory zone.",
  ranking_context: "Parallel risk profile to the Dubai option — both Gulf carriers carry advisory zone exposure on the Europe-to-Gulf leg. Qatar offers slightly better seat quality on this pair but comparable airspace risk.",
  watch_for: "MAD–DOH outbound leg transits the active Middle East advisory zone. DOH–SIN is clean. Qatar provides 2 daily MAD–DOH frequencies — adequate but less deep than Emirates' dual-daily on this pair.",
  explanation_bullets: [
    "MAD–DOH first leg (~6.5h) crosses the active Middle East advisory zone on the European departure segment.",
    "DOH–SIN second leg (~7.5h) routes southeast — clean sector, no active advisory exposure.",
    "Qatar Airways provides 2 daily MAD–DOH departures. Hamad International Airport (DOH) is among the world's highest-rated transit hubs.",
    "This option is structurally parallel to the Dubai routing in terms of airspace risk — the differentiation is product and pricing rather than safety profile.",
    "Total journey approximately 14 hours including transit — among the more time-efficient options on this corridor despite the Gulf routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Madrid → Singapore (3 corridor families: turkey_hub/IST, gulf_dubai/DXB, gulf_doha/DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# MADRID → BANGKOK
# Spanish-market long-haul to SE Asia. Strengthens both the Madrid origin cluster
# (currently only Singapore) and Bangkok's destination depth.
# Same Turkey/Gulf/Doha corridor logic applies as MAD→SIN.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily MAD–IST–BKK",
  path_geojson: line.([[mad.lng, mad.lat], [ist.lng, ist.lat], [68.0, 22.0], [bkk.lng, bkk.lat]]),
  distance_km: 11400, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best current option for MAD→BKK. Turkish Airlines via Istanbul avoids the Middle East advisory zone on both legs and provides the most direct viable path to Bangkok from Madrid.",
  ranking_context: "Ranks first because neither the MAD–IST nor IST–BKK leg transits the active Middle East advisory zone. Strong Turkish Airlines frequency on both segments gives adequate rebooking depth.",
  watch_for: "Turkish domestic political context occasionally affects IST operations. IST–BKK routes south of the Central Asian zone. Verify TK status 48h before departure.",
  explanation_bullets: [
    "MAD–IST (~4h) routes east across the Mediterranean — clean sector, no advisory zone transit.",
    "IST–BKK (~11h) routes southeast via Turkey's southern coast and the Indian subcontinent. Neither leg touches the active Middle East advisory zone.",
    "Turkish Airlines holds 2 daily MAD–IST and multiple daily IST–BKK services. Rebooking depth is solid.",
    "Istanbul (IST) sits within regional monitoring range of Ukraine but has operated without disruption throughout the post-2022 period.",
    "Total journey approximately 13 hours including transit. The most time-efficient clean-airspace option on this corridor."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily MAD–DXB–BKK",
  path_geojson: line.([[mad.lng, mad.lat], [15.0, 38.0], [dxb.lng, dxb.lat], [80.0, 18.0], [bkk.lng, bkk.lat]]),
  distance_km: 11700, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Popular Emirates option with strong frequency and premium hub infrastructure. The MAD–DXB outbound leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranked below Istanbul due to advisory zone transit on the outbound MAD–DXB leg. Emirates' DXB–BKK second leg is clean. Best rebooking option of the three if conditions change post-booking.",
  watch_for: "MAD–DXB leg transits the active Middle East advisory zone. DXB–BKK is clean. Monitor regional escalation levels before departure.",
  explanation_bullets: [
    "MAD–DXB first leg (~7h) crosses the active Middle East advisory zone — the primary differentiating risk on this routing.",
    "DXB–BKK second leg (~7h) routes southeast via Indian Ocean — clean sector, no advisory exposure.",
    "Emirates provides 2 daily MAD–DXB services, giving the strongest rebooking access of any option on this pair.",
    "Dubai (DXB) has operated without closure throughout the current conflict period.",
    "Total journey approximately 14 hours including transit — slightly longer than Istanbul due to Gulf routing geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: bkk.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · 2 daily MAD–DOH–BKK",
  path_geojson: line.([[mad.lng, mad.lat], [12.0, 37.0], [doh.lng, doh.lat], [80.0, 18.0], [bkk.lng, bkk.lat]]),
  distance_km: 11500, typical_duration_minutes: 820, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha offers good seat quality and reliable BKK connectivity. The MAD–DOH outbound leg crosses the active Middle East advisory zone.",
  ranking_context: "Parallel airspace risk to the Dubai option — both Gulf carriers cross the advisory zone on the Europe-to-Gulf outbound leg. Qatar differentiates on product and pricing rather than airspace profile.",
  watch_for: "MAD–DOH outbound leg transits the active Middle East advisory zone. DOH–BKK second leg is clean. Qatar provides adequate frequency for rebooking if conditions deteriorate.",
  explanation_bullets: [
    "MAD–DOH first leg (~6.5h) crosses the active Middle East advisory zone on the outbound segment.",
    "DOH–BKK second leg (~6h) routes southeast — clean, uncomplicated sector.",
    "Qatar Airways operates 2 daily MAD–DOH departures. Hamad International (DOH) is consistently rated among the world's best transit hubs.",
    "The airspace risk profile is structurally identical to the Dubai option — choose between them on product and price rather than safety differentiation.",
    "Total journey approximately 13.5 hours including transit."
  ],
  calculated_at: now
})

IO.puts("  ✓ Madrid → Bangkok (3 corridor families: turkey_hub/IST, gulf_dubai/DXB, gulf_doha/DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# MADRID → HONG KONG
# Strengthens Madrid origin cluster further. HKG as destination is well-served
# from EU4 but Madrid is missing. Via London (clean) · Via Istanbul (near zone) ·
# Via Dubai (advisory zone) — three genuinely distinct airspace profiles.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: hkg.id, via_hub_city_id: lhr.id,
  corridor_family: "direct",
  route_name: "Via London",
  carrier_notes: "British Airways (BA) + Cathay Pacific (CX) · MAD–LHR–HKG connection",
  path_geojson: line.([[mad.lng, mad.lat], [lhr.lng, lhr.lat], [50.0, 42.0], [85.0, 40.0], [hkg.lng, hkg.lat]]),
  distance_km: 12500, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Cleanest airspace option for MAD→HKG. BA to London connects with Cathay's Central Asian routing to Hong Kong — neither leg touches the Middle East advisory zone.",
  ranking_context: "Ranks first on airspace clarity: LHR–HKG uses the Central Asian corridor, entirely avoiding the Middle East zone. The brief LHR connection adds transfer complexity but no airspace risk.",
  watch_for: "LHR connection requires a terminal transfer and a minimum of 2–2.5 hours. BA MAD–LHR is a short hop (~2.5h) — ensure adequate connection time for luggage and terminal transit.",
  explanation_bullets: [
    "MAD–LHR first leg (~2.5h) is a clean short-haul intra-European sector — no advisory concerns.",
    "LHR–HKG second leg uses the Central Asian corridor, routing east via Kazakhstan and avoiding the Middle East zone entirely.",
    "Cathay Pacific operates multiple daily LHR–HKG services with strong on-time performance — good rebooking flexibility at Heathrow.",
    "This is the only clean-airspace (airspace_score=0) option for this city pair, making it the strongest choice if Gulf-zone avoidance is a priority.",
    "Total journey approximately 15 hours including the LHR transit — longer than Gulf options due to the double-hop geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: hkg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · MAD–IST–HKG",
  path_geojson: line.([[mad.lng, mad.lat], [ist.lng, ist.lat], [70.0, 35.0], [100.0, 28.0], [hkg.lng, hkg.lat]]),
  distance_km: 10800, typical_duration_minutes: 800, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Strong middle option. Turkish Airlines MAD→IST→HKG avoids the Middle East advisory zone on both legs and is more time-efficient than the via-London routing.",
  ranking_context: "Ranked second — near-zone exposure on the IST leg but neither segment transits the advisory zone. Shorter and simpler than the London connection with comparable corridor integrity.",
  watch_for: "IST–HKG routes through Central Asian corridors. Turkish Airlines operates this connection; verify availability as service frequency varies seasonally.",
  explanation_bullets: [
    "MAD–IST (~4h) routes cleanly east — no advisory zone involvement.",
    "IST–HKG (~10h) routes southeast via Turkey's southern coast and through Central Asia — neither segment transits the active Middle East advisory zone.",
    "Turkish Airlines provides IST–HKG service; connection availability should be confirmed for specific dates.",
    "IST hub sits within regional monitoring range of Ukraine but has not experienced operational disruption.",
    "Total journey approximately 13.5 hours including transit — more time-efficient than the London option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: mad.id, destination_city_id: hkg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · MAD–DXB–HKG",
  path_geojson: line.([[mad.lng, mad.lat], [15.0, 38.0], [dxb.lng, dxb.lat], [90.0, 22.0], [hkg.lng, hkg.lat]]),
  distance_km: 11400, typical_duration_minutes: 830, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai provides strong frequency and premium hub quality for MAD→HKG, but the outbound MAD–DXB leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranked below the London and Istanbul options due to advisory zone transit on the MAD–DXB outbound leg. Emirates' deep DXB–HKG frequency makes this the best rebooking option if disruption occurs post-booking.",
  watch_for: "MAD–DXB first leg crosses the Middle East advisory zone. DXB–HKG second leg is clean. Emirates operates 4+ daily DXB–HKG services — best rebooking flexibility of any option on this pair.",
  explanation_bullets: [
    "MAD–DXB first leg (~7h) crosses the active Middle East advisory zone — the primary differentiating risk factor.",
    "DXB–HKG second leg (~8h) routes northeast — clean sector.",
    "Emirates operates multiple daily DXB–HKG services, providing the strongest rebooking depth of the three corridor options.",
    "Dubai hub has maintained uninterrupted operations throughout the current conflict period.",
    "Total journey approximately 14 hours including transit."
  ],
  calculated_at: now
})

IO.puts("  ✓ Madrid → Hong Kong (3 corridor families: direct/LHR, turkey_hub/IST, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# TOKYO → FRANKFURT
# Strengthens Tokyo as an origin (currently only →London, →Amsterdam).
# NRT→FRA is one of the highest-volume Japan–Germany routes.
# Direct Central Asian · Via Seoul · Via Dubai — real corridor differentiation.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: fra.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct via Central Asia",
  carrier_notes: "Lufthansa (LH) · 1 daily NRT–FRA; ANA (NH) · 1 daily NRT–FRA",
  path_geojson: line.([[nrt.lng, nrt.lat], [110.0, 45.0], [85.0, 45.0], [55.0, 45.0], [30.0, 45.0], [fra.lng, fra.lat]]),
  distance_km: 9350, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Most direct and fastest option for NRT→FRA. Lufthansa and ANA both operate this route via the Central Asian corridor. Single-stop simplicity with no Gulf involvement.",
  ranking_context: "Ranks first on simplicity and speed. The Central Asian corridor is not in an active advisory zone — it passes near but not through restricted areas. No connection required.",
  watch_for: "The Central Asian corridor sees Eurocontrol flow restrictions on busy departure days. Check NRT departure slot status 24h before, particularly during summer peaks.",
  explanation_bullets: [
    "NRT–FRA routes directly west via Central Asia (Kazakhstan/Russia's southern flanks) — not through the Ukrainian restricted zone, which is further north.",
    "Lufthansa and ANA both maintain 1 daily NRT–FRA frequency each. Combined this gives reasonable rebooking options.",
    "No connection required — single departure from Narita, single arrival at Frankfurt. Simplest structure of the three options.",
    "The Central Asian routing has stabilized post-2022. Effective flight times have lengthened by ~1 hour versus the pre-2022 Russian airspace path but are now consistent.",
    "Total journey approximately 11 hours. Best choice for most NRT→FRA travellers under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: fra.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · 1 daily NRT–ICN–FRA; Asiana (OZ) · 1 daily NRT–ICN–FRA",
  path_geojson: line.([[nrt.lng, nrt.lat], [icn.lng, icn.lat], [85.0, 43.0], [50.0, 42.0], [fra.lng, fra.lat]]),
  distance_km: 10100, typical_duration_minutes: 710, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Via Seoul adds a brief ICN connection but routes through the same Central Asian corridor. Good choice if direct NRT–FRA capacity is limited or if you benefit from ICN's transit infrastructure.",
  ranking_context: "Comparable airspace profile to the direct option — both use the Central Asian corridor. Ranked slightly lower due to the additional connection, which adds schedule complexity without meaningful airspace benefit.",
  watch_for: "ICN connection requires 1.5–2h transit minimum. Korean Air and Asiana ICN–FRA services are daily but less frequent than LH/NH combined — check availability on specific travel dates.",
  explanation_bullets: [
    "NRT–ICN first leg (~2h) is a clean intra-Northeast Asian sector with no advisory concerns.",
    "ICN–FRA second leg uses the Central Asian corridor — same routing as the direct NRT–FRA option.",
    "Korean Air and Asiana both operate ICN–FRA. This gives two-carrier rebooking flexibility at Seoul.",
    "Seoul Incheon (ICN) is consistently rated among Asia's top transit hubs — efficient connections, strong infrastructure.",
    "Total journey approximately 12 hours including transit at ICN. Slightly longer than direct but useful if NRT–FRA direct availability is tight."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · NRT–DXB–FRA",
  path_geojson: line.([[nrt.lng, nrt.lat], [90.0, 20.0], [dxb.lng, dxb.lat], [30.0, 36.0], [fra.lng, fra.lat]]),
  distance_km: 13500, typical_duration_minutes: 870, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai is a premium option with strong hub infrastructure, but NRT→DXB routes south and DXB→FRA crosses the active Middle East advisory zone.",
  ranking_context: "Ranked below Central Asian options due to advisory zone transit on the DXB–FRA leg. Emirates' operational depth provides the best rebooking access of the three options if disruption occurs post-departure.",
  watch_for: "DXB–FRA second leg transits the active Middle East advisory zone. Emirates operates DXB–FRA daily — good rebooking frequency, but advisory zone exposure is the defining risk factor.",
  explanation_bullets: [
    "NRT–DXB first leg (~11h) routes southwest — clean sector with no active advisory zone involvement.",
    "DXB–FRA second leg (~7h) crosses the active Middle East advisory zone. This is the primary risk differentiating this option from the Central Asian alternatives.",
    "Emirates provides daily DXB–FRA service. Dubai hub has demonstrated strong operational resilience throughout the conflict period.",
    "Total journey approximately 14.5 hours including transit — significantly longer than Central Asian options due to more southerly geometry.",
    "This corridor is most useful if NRT–FRA direct capacity is unavailable, or for travellers specifically seeking Emirates' long-haul product."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Frankfurt (3 corridor families: central_asia, north_asia_icn/ICN, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# TOKYO → PARIS
# Strengthens Tokyo origins further. NRT→CDG is a high-volume Air France route.
# Same corridor logic as NRT→FRA: direct/Central Asia · Via Seoul · Via Dubai.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: cdg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct via Central Asia",
  carrier_notes: "Air France (AF) · 1 daily NRT–CDG; ANA (NH) · 1 daily NRT–CDG",
  path_geojson: line.([[nrt.lng, nrt.lat], [110.0, 45.0], [85.0, 45.0], [55.0, 44.0], [28.0, 44.0], [cdg.lng, cdg.lat]]),
  distance_km: 9710, typical_duration_minutes: 685, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Most direct and time-efficient option for NRT→CDG. Air France and ANA both operate this route via the Central Asian corridor. No Gulf involvement.",
  ranking_context: "Ranks first on speed and simplicity. The Central Asian routing passes near but not through the Ukrainian restricted zone — corridor is active and stable as of last assessment.",
  watch_for: "Central Asian corridor Eurocontrol flow restrictions can affect NRT–CDG departure slots on peak summer days. Check flight status 24h before departure.",
  explanation_bullets: [
    "NRT–CDG routes directly west via Central Asia — same structural routing as NRT→FRA direct but slightly longer due to CDG's more westerly position.",
    "Air France and ANA both operate 1 daily NRT–CDG frequency each. Combined rebooking flexibility is reasonable.",
    "No connection required — direct departure from Narita to Charles de Gaulle.",
    "The Central Asian routing post-2022 has added approximately 1 hour to NRT–CDG compared to the pre-closure Russian airspace path.",
    "Total journey approximately 11.5 hours. Best default choice for NRT→CDG under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: cdg.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · NRT–ICN–CDG; Air France (AF) codeshare",
  path_geojson: line.([[nrt.lng, nrt.lat], [icn.lng, icn.lat], [85.0, 43.0], [48.0, 43.0], [cdg.lng, cdg.lat]]),
  distance_km: 10400, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Via Seoul is a clean alternative when direct NRT–CDG capacity is limited. Same Central Asian corridor as the direct option, with a brief Seoul transit.",
  ranking_context: "Comparable airspace profile to the direct option. Ranked slightly lower due to the additional ICN connection adding schedule risk with no meaningful airspace benefit.",
  watch_for: "ICN transit requires minimum 1.5–2h connection. Korean Air/Air France ICN–CDG services are less frequent than the Air France NRT–CDG direct — confirm availability for your travel date.",
  explanation_bullets: [
    "NRT–ICN first leg (~2h) is a clean regional hop — no advisory zone involvement.",
    "ICN–CDG uses the Central Asian corridor, same structural routing as the direct option.",
    "Korean Air operates the ICN–CDG long-haul leg, with Air France codeshare availability on many dates.",
    "ICN transit is efficient — Incheon is consistently rated among Asia's best connecting hubs.",
    "Total journey approximately 12 hours including transit."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · NRT–DXB–CDG",
  path_geojson: line.([[nrt.lng, nrt.lat], [90.0, 20.0], [dxb.lng, dxb.lat], [28.0, 36.0], [cdg.lng, cdg.lat]]),
  distance_km: 13800, typical_duration_minutes: 890, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai offers premium long-haul comfort but the DXB–CDG second leg crosses the active Middle East advisory zone. Longest option time-wise.",
  ranking_context: "Ranked below Central Asian options due to advisory zone transit on the DXB–CDG leg. Best rebooking access of the three options owing to Emirates' daily DXB–CDG frequency.",
  watch_for: "DXB–CDG leg transits the active Middle East advisory zone. Emirates operates DXB–CDG daily. Monitor regional escalation before travel.",
  explanation_bullets: [
    "NRT–DXB first leg (~11h) routes southwest — clean sector with no active advisory involvement.",
    "DXB–CDG second leg (~7.5h) crosses the active Middle East advisory zone — the primary risk factor on this routing.",
    "Emirates provides daily DXB–CDG service. Dubai hub has maintained uninterrupted operations throughout the conflict period.",
    "Total journey approximately 14.5–15 hours including transit — significantly longer than Central Asian options.",
    "Choose this corridor for Emirates' premium product or when direct NRT–CDG capacity is unavailable, not for airspace risk optimization."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Paris (3 corridor families: central_asia, north_asia_icn/ICN, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# SYDNEY → FRANKFURT
# Expands the Sydney cluster (currently only London). SYD→FRA is a major
# AU–DE route — Lufthansa is the key carrier. Same three-corridor logic as SYD→LHR.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: fra.id, via_hub_city_id: sin.id,
  corridor_family: "direct",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) + Lufthansa (LH) · SYD–SIN–FRA",
  path_geojson: line.([[syd.lng, syd.lat], [sin.lng, sin.lat], [75.0, 25.0], [48.0, 38.0], [fra.lng, fra.lat]]),
  distance_km: 17100, typical_duration_minutes: 1200, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best current option for SYD→FRA. SYD–SIN is a clean regional sector; SIN–FRA uses the Central Asian corridor with no advisory zone transit on either leg.",
  ranking_context: "Ranks first because neither leg touches the Middle East advisory zone. Singapore provides the deepest rebooking infrastructure of the three mid-route hub options.",
  watch_for: "SIN–FRA second leg uses the Central Asian corridor. If Eurocontrol flow restrictions are active on arrival day, this segment may be affected. Changi's hub depth provides good recovery options.",
  explanation_bullets: [
    "SYD–SIN first leg (~7.5h) is a clean, uncomplicated sector with no advisory zone exposure.",
    "SIN–FRA second leg (~13h) uses the Central Asian routing — not through the Ukrainian zone, which is further north.",
    "Singapore Airlines and Lufthansa both serve SIN–FRA, providing two-carrier rebooking options at Singapore.",
    "Changi Airport (SIN) offers the strongest mid-route hub infrastructure of the three options — efficient connections, extensive lounge facilities.",
    "Total journey approximately 20 hours including transit. This is the cleanest airspace profile for SYD→FRA."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: fra.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) + Lufthansa (LH) · SYD–HKG–FRA",
  path_geojson: line.([[syd.lng, syd.lat], [hkg.lng, hkg.lat], [85.0, 40.0], [48.0, 38.0], [fra.lng, fra.lat]]),
  distance_km: 17700, typical_duration_minutes: 1250, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean airspace on both legs. SYD–HKG is a major regional route; HKG–FRA uses the Central Asian corridor. Good choice if Singapore availability is limited.",
  ranking_context: "Same clean airspace category as Singapore routing. Ranked lower due to HKG–FRA running through the most congested Central Asian corridor band, with higher schedule risk on the second leg.",
  watch_for: "HKG–FRA runs through the most congested Central Asian corridor slot for Frankfurt-bound traffic. Eurocontrol flow restrictions affect this routing more frequently than SIN-originating traffic.",
  explanation_bullets: [
    "SYD–HKG first leg (~9h) is a clean major regional route — no advisory zone involvement.",
    "HKG–FRA second leg uses the Central Asian corridor. Cathay Pacific has maintained consistent HKG–FRA service since 2022.",
    "Hong Kong hub is an efficient connecting point with strong Cathay Pacific infrastructure for this routing.",
    "Total journey approximately 21 hours including transit — slightly longer than the Singapore option due to HKG's position.",
    "Best used when SIN availability is constrained or for travellers making connections at HKG."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · SYD–DXB–FRA",
  path_geojson: line.([[syd.lng, syd.lat], [90.0, 5.0], [dxb.lng, dxb.lat], [30.0, 37.0], [fra.lng, fra.lat]]),
  distance_km: 17500, typical_duration_minutes: 1230, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai is the highest-frequency option for SYD→FRA, but the DXB–FRA second leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranked below Singapore and Hong Kong due to advisory zone transit on the DXB–FRA leg. Emirates provides the deepest rebooking access of any option on this pair.",
  watch_for: "DXB–FRA second leg crosses the active Middle East advisory zone. Emirates offers strong frequency and operational depth at DXB — best recovery option if disruption occurs post-departure.",
  explanation_bullets: [
    "SYD–DXB first leg (~14h) routes northwest via Indian Ocean — clean sector, no advisory exposure.",
    "DXB–FRA second leg (~7h) crosses the active Middle East advisory zone. This is the primary risk differentiating it from the Singapore and Hong Kong options.",
    "Emirates provides SYD–DXB–FRA with daily frequency and strong onward connectivity. DXB has maintained full operations throughout the conflict period.",
    "The via-Dubai routing geometry is not significantly longer than other options for the SYD→FRA pair — the risk differential is in airspace, not journey time.",
    "Total journey approximately 20.5 hours including transit."
  ],
  calculated_at: now
})

IO.puts("  ✓ Sydney → Frankfurt (3 corridor families: via SIN, via HKG/north_asia_hkg, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → AMSTERDAM
# Three families: central_asia (Direct, KE) · north_asia_hkg · gulf_dubai
# Seoul→Amsterdam strengthens ICN as origin hub — was London-only.
# Direct via Central Asia ranks first: avoids Gulf exposure, Korean Air has the route.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: ams.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Korean Air (KE) · 1 daily ICN–AMS via Central Asian corridor",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 45.0], [65.0, 48.0], [35.0, 50.0], [ams.lng, ams.lat]]),
  distance_km: 8800, typical_duration_minutes: 640, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Most direct ICN→AMS option. Korean Air routes via the Central Asian corridor — level-1 advisory only, no Gulf exposure.",
  ranking_context: "Ranks first: avoids the active Middle East advisory zone entirely. Central Asian corridor carries a persistent level-1 advisory but not the active zone. Direct routing eliminates connection risk.",
  watch_for: "Central Asian corridor carries a persistent level-1 advisory. Check Korean Air NOTAM status 48 hours before departure if Central Asian flow restrictions are active.",
  explanation_bullets: [
    "ICN→AMS routes west via Central Asian airspace — level-1 advisory, not through the active Middle East zone.",
    "Korean Air is the primary direct carrier on this pair. Single-carrier dependency means fewer rebooking options on the same day.",
    "Direct routing removes the largest risk on this corridor: a missed Gulf hub connection during active regional tension.",
    "Journey time approximately 10.5 hours — well-established route with consistent performance since 2023 rerouting settled.",
    "If Korean Air is disrupted, via-HKG (Cathay Pacific) is the best same-day backup with no Gulf exposure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: ams.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · ICN–HKG–AMS · 3+ daily ICN–HKG departures",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat], [65.0, 40.0], [35.0, 48.0], [ams.lng, ams.lat]]),
  distance_km: 9600, typical_duration_minutes: 695, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Strong backup via Cathay's Hong Kong hub. ICN–HKG is clean; HKG–AMS uses the Central Asian corridor. Best rebooking depth of the non-Gulf options.",
  ranking_context: "Ranks just below direct: the connection point adds schedule risk, but Cathay's 3+ daily ICN–HKG frequency gives strong rebooking options. Ranks above Dubai due to no Gulf advisory exposure.",
  watch_for: "HKG–AMS second leg uses the Central Asian corridor — same advisory category as the direct option. Cathay has maintained consistent HKG–AMS service since 2022.",
  explanation_bullets: [
    "ICN→HKG first leg is clean — South China Sea airspace, no advisory zone involvement.",
    "HKG→AMS routes via the Central Asian corridor — level-1 advisory, no Gulf exposure. Same structural risk category as the direct option.",
    "Cathay Pacific offers 3+ daily ICN–HKG departures — substantially better frequency than the single Korean Air direct.",
    "HKG is one of the most resilient East Asian hubs for European connections, with deep onward connectivity.",
    "Adds approximately 1 hour versus direct due to the connection geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · ICN–DXB–AMS · 2 daily ICN–DXB departures",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 30.0], [dxb.lng, dxb.lat], [32.0, 38.0], [ams.lng, ams.lat]]),
  distance_km: 11000, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates option. ICN→DXB is clean, but DXB→AMS crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below both Central Asian options due to advisory zone transit on DXB→AMS. Emirates frequency is an advantage, but the airspace exposure is the key differentiator.",
  watch_for: "DXB→AMS second leg crosses the active Middle East advisory zone. Emirates provides strong rebooking options at DXB, but the advisory exposure is the defining risk on this routing.",
  explanation_bullets: [
    "ICN→DXB first leg routes south through Southeast Asia and Indian Ocean — no advisory zone exposure.",
    "DXB→AMS second leg crosses the active Middle East advisory zone. This is the primary risk differentiating it from Central Asian options.",
    "Emirates offers 2 daily ICN–DXB departures — better frequency than Korean Air direct, useful as a rebooking fallback.",
    "Dubai has operated without closure throughout the current conflict period but regional escalation remains a variable.",
    "Adds approximately 2 hours versus the direct option due to southerly Gulf routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Amsterdam (3 corridor families: central_asia/Direct, north_asia_hkg, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → FRANKFURT
# Three families: central_asia (Direct) · north_asia_hkg · gulf_dubai
# Mirrors Seoul→Amsterdam logic; FRA is the other major German hub.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: fra.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Korean Air (KE) / Lufthansa (LH) codeshare · 1 daily ICN–FRA via Central Asian corridor",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 45.0], [65.0, 47.0], [38.0, 48.0], [fra.lng, fra.lat]]),
  distance_km: 8700, typical_duration_minutes: 635, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Most direct ICN→FRA option. Korean Air/Lufthansa codeshare via the Central Asian corridor — level-1 advisory only, no Gulf exposure.",
  ranking_context: "Ranks first: avoids the active Middle East advisory zone. Central Asian corridor carries a persistent level-1 advisory. Direct routing eliminates connection risk and benefits from KE/LH codeshare rebooking depth.",
  watch_for: "Central Asian corridor carries a persistent level-1 advisory. The KE/LH codeshare means disruption can be rebooked on either carrier — better resilience than typical single-carrier direct.",
  explanation_bullets: [
    "ICN→FRA routes west via Central Asian airspace — level-1 advisory, not through the active Middle East advisory zone.",
    "Korean Air and Lufthansa operate this as a codeshare, providing unusually good rebooking optionality for a nominally direct service.",
    "Direct routing avoids the biggest structural risk: a missed Gulf connection during active regional disruption.",
    "Journey time approximately 10.5 hours. FRA is a significantly larger transfer hub than AMS, giving better onward options if delays occur.",
    "Via-HKG (Cathay) is the strongest backup if Central Asian flow restrictions tighten."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: fra.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) + Lufthansa (LH) · ICN–HKG–FRA · 3+ daily ICN–HKG",
  path_geojson: line.([[icn.lng, icn.lat], [hkg.lng, hkg.lat], [68.0, 40.0], [38.0, 47.0], [fra.lng, fra.lat]]),
  distance_km: 9500, typical_duration_minutes: 690, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Solid backup via Cathay's Hong Kong hub. ICN–HKG is clean; HKG–FRA uses the Central Asian corridor. Higher frequency than direct at the cost of a connection.",
  ranking_context: "Ranks below direct due to connection point, but Cathay's 3+ daily ICN–HKG departures make it the best backup option. Ranks above Dubai due to no Gulf advisory exposure.",
  watch_for: "HKG–FRA uses the Central Asian corridor — same advisory category as direct routing. Eurocontrol flow restrictions occasionally affect FRA arrival slots for Central Asia–originating flights.",
  explanation_bullets: [
    "ICN→HKG first leg is clean — South China Sea airspace, no advisory zone involvement.",
    "HKG→FRA routes via Central Asian corridor — level-1 advisory, no Gulf exposure. Same structural risk as the direct option.",
    "Cathay Pacific's 3+ daily ICN–HKG frequency is a meaningful advantage when rebooking is required.",
    "Frankfurt is the strongest European hub for Central Asia–routed traffic, with Lufthansa providing deep onward connectivity.",
    "Adds approximately 1 hour versus direct due to the Hong Kong connection geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · ICN–DXB–FRA · 2 daily ICN–DXB departures",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 30.0], [dxb.lng, dxb.lat], [30.0, 37.0], [fra.lng, fra.lat]]),
  distance_km: 11100, typical_duration_minutes: 785, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates option. ICN→DXB is clean, but DXB→FRA crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below Central Asian options due to DXB→FRA advisory zone exposure. Emirates frequency is an advantage for rebooking, but the airspace risk differentiates it from the direct and via-HKG options.",
  watch_for: "DXB→FRA second leg crosses the active Middle East advisory zone. Emirates provides strong rebooking options at DXB, but this is the defining risk on this routing.",
  explanation_bullets: [
    "ICN→DXB routes south through Southeast Asia and Indian Ocean — no advisory zone involvement on the first leg.",
    "DXB→FRA second leg crosses the active Middle East advisory zone. This is the primary differentiator versus the Central Asian options.",
    "Emirates' 2 daily ICN–DXB departures provide better frequency than the KE/LH direct and are useful for same-day rebooking.",
    "Dubai has operated continuously throughout the current conflict period, but regional escalation remains a variable to monitor.",
    "Total journey adds approximately 2+ hours versus direct due to the southerly Gulf routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Frankfurt (3 corridor families: central_asia/Direct, north_asia_hkg, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# SEOUL → PARIS
# Three families: central_asia (Direct) · gulf_istanbul · gulf_dubai
# Paris/CDG is served by Air France from ICN. IST adds a middle-ground option.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: cdg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air France (AF) · 1 daily ICN–CDG via Central Asian corridor",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 45.0], [65.0, 48.0], [38.0, 49.0], [cdg.lng, cdg.lat]]),
  distance_km: 9000, typical_duration_minutes: 650, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Most direct ICN→CDG option. Air France routes via the Central Asian corridor — level-1 advisory, no Gulf exposure.",
  ranking_context: "Ranks first: avoids the active Middle East advisory zone entirely. Central Asian corridor carries a persistent level-1 advisory. Direct routing eliminates connection risk and Air France CDG operations are deeply connected.",
  watch_for: "Central Asian corridor carries a persistent level-1 advisory. Check Air France NOTAM status 48 hours before departure if Central Asian flow restrictions are active.",
  explanation_bullets: [
    "ICN→CDG direct routes west via Central Asian airspace — level-1 advisory, not through the active Middle East zone.",
    "Air France is the sole direct carrier on this city pair; fewer same-day rebooking options if disrupted.",
    "CDG is Air France's hub — strong onward connectivity if you need to reroute upon arrival.",
    "Journey time approximately 11 hours — consistent since 2023 rerouting.",
    "If Air France is disrupted, via-IST (Turkish Airlines) is the cleanest non-Gulf backup."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: cdg.id, via_hub_city_id: ist.id,
  corridor_family: "gulf_istanbul",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · ICN–IST–CDG · 1 daily ICN–IST",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 43.0], [68.0, 42.0], [ist.lng, ist.lat], [cdg.lng, cdg.lat]]),
  distance_km: 9700, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Turkish Airlines via Istanbul. ICN–IST uses the Central Asian corridor; IST–CDG is clean westbound over the Mediterranean. Good frequency backup if Air France is disrupted.",
  ranking_context: "Ranks second behind direct: Central Asian corridor risk is shared with the direct option, but the IST hub adds a connection point. Ranks ahead of Dubai because IST–CDG avoids the advisory zone entirely.",
  watch_for: "ICN–IST first leg uses the Central Asian corridor — same level-1 advisory as the direct option. IST–CDG is a clean Mediterranean routing with no advisory zone involvement.",
  explanation_bullets: [
    "ICN→IST routes via the Central Asian corridor — level-1 advisory, same structural risk category as the Air France direct.",
    "IST→CDG is a clean westbound sector over the Mediterranean — no advisory zone involvement on the second leg.",
    "Turkish Airlines offers daily ICN–IST service, providing a viable backup frequency when Air France is constrained.",
    "Istanbul (IST) is a large resilient hub with strong CDG onward frequency — multiple daily departures to Paris.",
    "Adds approximately 1.5 hours versus direct due to the IST connection geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · ICN–DXB–CDG · 2 daily ICN–DXB departures",
  path_geojson: line.([[icn.lng, icn.lat], [100.0, 30.0], [dxb.lng, dxb.lat], [28.0, 37.0], [cdg.lng, cdg.lat]]),
  distance_km: 11200, typical_duration_minutes: 795, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates option. ICN→DXB is clean, but DXB→CDG crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below Central Asian and Istanbul options due to advisory zone transit on DXB→CDG. Emirates frequency is an operational advantage but the airspace risk is the defining differentiator.",
  watch_for: "DXB→CDG second leg crosses the active Middle East advisory zone. Emirates has strong rebooking options at DXB, but this is the defining risk on this routing.",
  explanation_bullets: [
    "ICN→DXB routes south through Southeast Asia and Indian Ocean — no advisory zone on the first leg.",
    "DXB→CDG second leg crosses the active Middle East advisory zone. This is the primary risk versus Central Asian and Istanbul routing.",
    "Emirates' 2 daily ICN–DXB departures provide the best raw frequency of the three options — useful for same-day rebooking.",
    "Dubai has operated continuously throughout the current conflict period; regional escalation is the variable to watch.",
    "Adds approximately 2+ hours versus direct due to southerly Gulf routing geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Paris (3 corridor families: central_asia/Direct, gulf_istanbul/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → MADRID
# Three families: gulf_istanbul · gulf_dubai · gulf_doha
# BKK→MAD has no direct service — all options require a hub stop.
# Turkish Airlines via IST is the structurally cleanest option.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: mad.id, via_hub_city_id: ist.id,
  corridor_family: "gulf_istanbul",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · BKK–IST–MAD · 2 daily BKK–IST departures",
  path_geojson: line.([[bkk.lng, bkk.lat], [85.0, 32.0], [ist.lng, ist.lat], [mad.lng, mad.lat]]),
  distance_km: 9800, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Structurally cleanest BKK→MAD option. Turkish Airlines via Istanbul avoids the active Middle East advisory zone on both legs. Best available for this pair.",
  ranking_context: "Ranks first: IST avoids the Gulf advisory zone entirely. BKK–IST routes over South Asia with a persistent level-1 advisory; IST–MAD is clean. No other option avoids the advisory zone as well.",
  watch_for: "BKK–IST first leg routes over South Asia — level-1 peripheral advisory near Pakistan/Afghanistan airspace. IST–MAD second leg is clean over the Mediterranean.",
  explanation_bullets: [
    "BKK→IST first leg routes northwest over South Asia — level-1 advisory near Pakistan/Afghanistan airspace, but no active advisory zone transit.",
    "IST→MAD second leg is clean — westbound over the Mediterranean with no advisory zone involvement.",
    "Turkish Airlines operates 2 daily BKK–IST departures, providing reasonable rebooking options if the first departure is disrupted.",
    "Istanbul is geographically well-positioned between Bangkok and Madrid — less total journey time than Gulf hub options despite a longer first leg.",
    "Best-in-class for this pair given no Gulf advisory exposure on either segment."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: mad.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · BKK–DXB–MAD · daily BKK–DXB service",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [25.0, 34.0], [mad.lng, mad.lat]]),
  distance_km: 10500, typical_duration_minutes: 770, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai has strong frequency, but the DXB→MAD second leg crosses the active Middle East advisory zone.",
  ranking_context: "Ranks below Istanbul due to advisory zone transit on DXB→MAD. Emirates' operational depth at DXB is an advantage for rebooking if disruption occurs post-departure.",
  watch_for: "DXB→MAD second leg crosses the active Middle East advisory zone. Emirates has the deepest operational coverage at DXB — best recovery option if disruption occurs.",
  explanation_bullets: [
    "BKK→DXB first leg routes northwest over the Indian Ocean — clean sector, no advisory zone involvement.",
    "DXB→MAD second leg crosses the active Middle East advisory zone. This is the primary risk differentiating it from the Istanbul option.",
    "Emirates provides daily BKK–DXB service with strong frequency — useful when Turkish Airlines capacity is constrained.",
    "Dubai (DXB) has maintained continuous operations throughout the current conflict period. Hub closure risk is low but non-zero.",
    "Adds approximately 30–45 minutes versus the Istanbul option due to the southerly Gulf routing geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: mad.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · BKK–DOH–MAD · daily BKK–DOH service",
  path_geojson: line.([[bkk.lng, bkk.lat], [90.0, 22.0], [doh.lng, doh.lat], [22.0, 33.0], [mad.lng, mad.lat]]),
  distance_km: 10300, typical_duration_minutes: 755, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Similar advisory exposure to the Dubai option — DOH→MAD also crosses the active Middle East advisory zone.",
  ranking_context: "Comparable to Dubai routing: advisory zone exposure on the second leg is the same structural constraint. Ranks slightly ahead of Dubai on total journey geometry; behind Istanbul due to advisory exposure.",
  watch_for: "DOH→MAD second leg crosses the active Middle East advisory zone — same risk category as DXB→MAD. Qatar Airways offers strong rebooking options at DOH.",
  explanation_bullets: [
    "BKK→DOH first leg routes northwest over the Bay of Bengal and Indian subcontinent — clean sector, no advisory zone on this leg.",
    "DOH→MAD second leg crosses the active Middle East advisory zone — same structural risk as the Dubai option.",
    "Qatar Airways provides daily BKK–DOH service with strong westbound onward connectivity.",
    "Doha and Dubai present equivalent advisory risk on the BKK→MAD routing — choice between them is primarily driven by preferred carrier and schedule availability.",
    "Slightly more geographically direct than DXB for BKK→MAD, giving a marginal journey time advantage."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Madrid (3 corridor families: gulf_istanbul/IST, gulf_dubai, gulf_doha)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG → MADRID
# Three families: gulf_istanbul · north_asia_lhr (via London) · gulf_dubai
# HKG→MAD has no direct service. Via London gives a clean-airspace option.
# IST and LHR both rank ahead of Dubai; LHR uniquely provides airspace=0 option.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: mad.id, via_hub_city_id: lhr.id,
  corridor_family: "north_asia_lhr",
  route_name: "Via London",
  carrier_notes: "Cathay Pacific (CX) + British Airways (BA) or Iberia (IB) · HKG–LHR–MAD · daily CX HKG–LHR",
  path_geojson: line.([[hkg.lng, hkg.lat], [68.0, 42.0], [40.0, 48.0], [lhr.lng, lhr.lat], [mad.lng, mad.lat]]),
  distance_km: 13200, typical_duration_minutes: 930, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Cleanest airspace option for HKG→MAD. HKG–LHR uses the Central Asian corridor (clean post-2022 rerouting); LHR–MAD is clean. No advisory zone on either leg.",
  ranking_context: "Ranks first on airspace: the only HKG→MAD option with no advisory zone contact on either leg. Complexity score reflects the two-stop geometry and total journey time (~16 hours), but the airspace cleanliness is the primary differentiator.",
  watch_for: "HKG–LHR uses the Central Asian corridor — Cathay's post-2022 routing avoids active advisory zones. LHR–MAD is a clean short-haul sector. Longest total journey time of the three options.",
  explanation_bullets: [
    "HKG→LHR first leg uses Cathay Pacific's Central Asian corridor routing — no active advisory zone contact post-2022 rerouting.",
    "LHR→MAD second leg is a clean short-haul sector via British Airways or Iberia — no advisory zone involvement.",
    "The LHR hub break adds complexity: total journey is approximately 16 hours including transit. Worth it if avoiding advisory exposure is the priority.",
    "London (LHR) is the strongest European hub for HKG-originating traffic — deep Cathay and British Airways frequency.",
    "Best choice when minimising airspace risk is more important than minimising journey time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: mad.id, via_hub_city_id: ist.id,
  corridor_family: "gulf_istanbul",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · HKG–IST–MAD · 2 daily HKG–IST departures",
  path_geojson: line.([[hkg.lng, hkg.lat], [85.0, 38.0], [ist.lng, ist.lat], [mad.lng, mad.lat]]),
  distance_km: 11400, typical_duration_minutes: 830, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Best journey-time balance for HKG→MAD. Turkish Airlines via Istanbul — HKG–IST uses Central Asian corridor (level-1 advisory); IST–MAD is clean.",
  ranking_context: "Ranks second: level-1 advisory on the first leg prevents an airspace=0 score, but avoids the active advisory zone entirely. Better journey time than via London; better airspace than via Dubai.",
  watch_for: "HKG–IST first leg uses the Central Asian corridor — level-1 advisory near Pakistan/Afghanistan airspace. IST–MAD is clean. Turkish Airlines offers 2 daily HKG–IST departures.",
  explanation_bullets: [
    "HKG→IST routes via the Central Asian corridor — level-1 advisory, not through the active Middle East zone.",
    "IST→MAD second leg is clean — westbound over the Mediterranean with no advisory zone involvement.",
    "Turkish Airlines offers 2 daily HKG–IST departures, providing viable same-day rebooking options.",
    "Istanbul is geographically well-positioned between HKG and MAD — total journey approximately 13.5 hours, significantly shorter than via London.",
    "Best option when balancing journey time against airspace quality for this pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: mad.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · HKG–DXB–MAD · daily HKG–DXB service",
  path_geojson: line.([[hkg.lng, hkg.lat], [90.0, 20.0], [dxb.lng, dxb.lat], [25.0, 34.0], [mad.lng, mad.lat]]),
  distance_km: 12200, typical_duration_minutes: 875, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates option. HKG→DXB is clean, but DXB→MAD crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked third due to advisory zone transit on DXB→MAD. Emirates' frequency and DXB hub depth are operational advantages, but the airspace exposure is the defining differentiator versus London and Istanbul routing.",
  watch_for: "DXB→MAD second leg crosses the active Middle East advisory zone. Emirates provides the deepest rebooking options at DXB — best recovery if disruption occurs post-departure.",
  explanation_bullets: [
    "HKG→DXB first leg routes south and west over the South China Sea and Indian Ocean — clean sector, no advisory zone.",
    "DXB→MAD second leg crosses the active Middle East advisory zone. This is the primary risk differentiating it from London and Istanbul options.",
    "Emirates provides daily HKG–DXB service with strong frequency — useful when Turkish Airlines or Cathay capacity is constrained.",
    "Dubai has maintained continuous operations throughout the current conflict period; hub access risk remains low but non-zero.",
    "Total journey approximately 14.5 hours — shorter than via London, longer than via Istanbul."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Madrid (3 corridor families: north_asia_lhr/LHR, gulf_istanbul/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → SINGAPORE
# Three families: direct · south_asia_bkk · south_asia_kul
# Clean corridor — DEL→SIN routes southeastward with no advisory zone exposure.
# All three options are airspace=0; differentiation is hub quality and frequency.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Air India (AI) / IndiGo (6E) · Multiple daily DEL–SIN departures",
  path_geojson: line.([[del.lng, del.lat], [90.0, 15.0], [sin.lng, sin.lat]]),
  distance_km: 4150, typical_duration_minutes: 320, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for DEL→SIN. Clean southeastward routing with no advisory zone exposure. Multiple carriers and strong daily frequency.",
  ranking_context: "Ranks first: no advisory exposure, direct routing eliminates connection risk, and multiple carriers (Air India, IndiGo) give solid rebooking options for a direct flight.",
  watch_for: nil,
  explanation_bullets: [
    "DEL→SIN routes south and east through Indian airspace and over the Bay of Bengal — no advisory zone involvement on this corridor.",
    "Multiple daily departures across Air India and IndiGo give strong same-day rebooking options if the first flight is disrupted.",
    "Direct routing eliminates the risk of a missed connection at a hub that could add 5–8 hours to your journey.",
    "Singapore Airlines also operates the reverse SIN–DEL route; check interline options if Air India direct is full.",
    "At approximately 5.5 hours, this is one of the cleanest long-haul corridors currently operating without advisory zone contact."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: sin.id, via_hub_city_id: bkk.id,
  corridor_family: "south_asia_bkk",
  route_name: "Via Bangkok",
  carrier_notes: "Thai Airways (TG) · DEL–BKK–SIN · Multiple daily DEL–BKK departures",
  path_geojson: line.([[del.lng, del.lat], [bkk.lng, bkk.lat], [sin.lng, sin.lat]]),
  distance_km: 4650, typical_duration_minutes: 370, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Solid backup via Bangkok hub. DEL–BKK–SIN adds a connection but gives Thai Airways frequency and good onward options.",
  ranking_context: "Ranks second: same clean airspace as direct, but the Bangkok connection adds schedule risk and journey time. Thai's DEL–BKK frequency makes it a viable backup when direct options are full.",
  watch_for: nil,
  explanation_bullets: [
    "DEL→BKK first leg routes southeast over Myanmar — no advisory zone exposure on either segment.",
    "BKK→SIN is a high-frequency short hop (~2h). Thai Airways and other carriers operate this connection with strong daily departure options.",
    "Bangkok (BKK) is a well-established Southeast Asian hub with multiple onward connections if SIN-bound flights are disrupted.",
    "Adds approximately 1 hour versus direct due to the Bangkok connection geometry and layover.",
    "Best used when direct DEL–SIN capacity is constrained or when a Bangkok stop fits your itinerary."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: sin.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · DEL–KUL–SIN",
  path_geojson: line.([[del.lng, del.lat], [88.0, 12.0], [kul.lng, kul.lat], [sin.lng, sin.lat]]),
  distance_km: 4950, typical_duration_minutes: 400, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Via Kuala Lumpur offers budget and LCC options. Both legs are clean. Best when direct or Bangkok routing is full or significantly more expensive.",
  ranking_context: "Ranks third: same clean airspace as alternatives but two-leg geometry (DEL–KUL–SIN) is longer and KUL hub score is lower than BKK for this pair. Budget-carrier availability is the main use case.",
  watch_for: nil,
  explanation_bullets: [
    "DEL→KUL routes south and southeast — clean corridor with no advisory zone involvement.",
    "KUL→SIN is one of the world's busiest short-haul routes (~40 minutes). Extremely high frequency including multiple LCC options.",
    "Malaysia Airlines and AirAsia X serve DEL–KUL with competitive pricing. Useful when Air India or IndiGo direct is full or expensive.",
    "Total journey is longer than the Bangkok option due to KUL's position south of BKK relative to the SIN destination.",
    "Good choice if your budget is flexible but direct options are sold out."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Singapore (3 corridor families: direct, south_asia_bkk, south_asia_kul)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → BANGKOK
# Three families: direct · south_asia_sin · south_asia_kul
# Clean southeastward routing — no advisory zone exposure on any option.
# High-volume pair; differentiation is carrier depth and connection quality.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Air India (AI) / IndiGo (6E) / Thai Airways (TG) · Multiple daily DEL–BKK",
  path_geojson: line.([[del.lng, del.lat], [86.0, 22.0], [bkk.lng, bkk.lat]]),
  distance_km: 2950, typical_duration_minutes: 225, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option. Clean southeastern routing with no advisory exposure and multiple carriers. High frequency makes rebooking straightforward.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, and the highest carrier count of the three options. Air India, IndiGo, and Thai Airways all serve this pair.",
  watch_for: nil,
  explanation_bullets: [
    "DEL→BKK routes southeast over Myanmar — no advisory zone involvement. One of the cleanest medium-haul corridors currently operating.",
    "Air India and IndiGo both serve this pair with multiple daily departures. Thai Airways operates the reverse direction also.",
    "At approximately 3.5 hours, this is a short enough flight that disruption is typically resolved within the same day.",
    "Bangkok (BKK) has strong onward connections to Southeast Asia — useful if you're continuing beyond Bangkok.",
    "No significant airspace routing constraint exists on this corridor under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: bkk.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_sin",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) / Air India (AI) · DEL–SIN–BKK",
  path_geojson: line.([[del.lng, del.lat], [sin.lng, sin.lat], [bkk.lng, bkk.lat]]),
  distance_km: 5350, typical_duration_minutes: 440, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Via Singapore extends journey time significantly but provides Singapore Airlines quality and the world's best-connected Southeast Asian hub.",
  ranking_context: "Ranks second: same clean airspace, but the via-Singapore geometry adds 2+ hours to what is normally a 3.5-hour journey. Worth considering if Singapore Airlines connectivity is important.",
  watch_for: nil,
  explanation_bullets: [
    "DEL→SIN first leg is clean. SIN→BKK second leg is clean. No advisory zone on either segment.",
    "Singapore (SIN) is one of the world's strongest airline hubs — if SIN–BKK is disrupted, onward options are extensive.",
    "Singapore Airlines operates DEL–SIN–BKK with premium quality across both legs.",
    "The routing goes southeast then northwest — significant geometry overhead versus direct. Total journey is approximately 7.5 hours.",
    "Best used when SQ quality or SIN lounge access is a priority, or when direct DEL–BKK is full."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: bkk.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · DEL–KUL–BKK",
  path_geojson: line.([[del.lng, del.lat], [88.0, 12.0], [kul.lng, kul.lat], [bkk.lng, bkk.lat]]),
  distance_km: 5100, typical_duration_minutes: 415, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Both legs clean, but routing goes south of destination before heading north to BKK — geometry is inefficient.",
  ranking_context: "Ranks third: same clean airspace but the KUL hub is further south of Bangkok than SIN, making the overall geometry less efficient. Lower hub score than SIN for this pair.",
  watch_for: nil,
  explanation_bullets: [
    "DEL→KUL–BKK routes south through the Bay of Bengal then loops north to Bangkok — clean but geometrically roundabout.",
    "Malaysia Airlines and AirAsia X offer competitive pricing on the DEL–KUL leg. KUL–BKK has high frequency including LCC options.",
    "Total journey approximately 7 hours — slightly shorter than via Singapore but with a less prestigious hub connection.",
    "Best used for budget travel when direct DEL–BKK and via-SIN options are expensive or unavailable.",
    "No advisory concern on this routing under current conditions."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Bangkok (3 corridor families: direct, south_asia_sin, south_asia_kul)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → FRANKFURT
# Three families: central_asia (direct) · gulf_istanbul · gulf_dubai
# This is the key India→Europe pair where airspace exposure matters.
# Air India's direct DEL→FRA uses the Central Asian corridor (airspace=1).
# Via Istanbul avoids Gulf; via Dubai transits the active advisory zone on second leg.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: fra.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air India (AI) · 1 daily DEL–FRA via Central Asian corridor; Lufthansa (LH) codeshare",
  path_geojson: line.([[del.lng, del.lat], [65.0, 40.0], [45.0, 44.0], [fra.lng, fra.lat]]),
  distance_km: 6200, typical_duration_minutes: 465, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Most direct DEL→FRA option. Air India/Lufthansa codeshare via Central Asian corridor — level-1 advisory only, no Gulf exposure.",
  ranking_context: "Ranks first: avoids the active Gulf advisory zone. Central Asian corridor has a persistent level-1 advisory but no active zone transit. KE/LH codeshare gives better rebooking depth than a typical Air India single-carrier direct.",
  watch_for: "Central Asian corridor carries a persistent level-1 advisory near Kazakhstan/Caspian. Check Air India NOTAM status 48h before if Central Asian flow restrictions are active.",
  explanation_bullets: [
    "DEL→FRA routes northwest via the Central Asian corridor — level-1 advisory, not through the active Gulf advisory zone.",
    "Air India and Lufthansa operate this as a codeshare, providing rebooking options on either carrier if disruption occurs.",
    "Direct routing eliminates the Gulf hub connection risk that affects Emirates and Qatar Airways options.",
    "Journey time approximately 7.75 hours — consistently well-operated since Air India updated its Central Asian routing in 2023.",
    "Via-Istanbul (Turkish Airlines) is the strongest backup if Central Asian flow restrictions tighten."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: fra.id, via_hub_city_id: ist.id,
  corridor_family: "gulf_istanbul",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily DEL–IST · IST–FRA multiple daily",
  path_geojson: line.([[del.lng, del.lat], [58.0, 38.0], [ist.lng, ist.lat], [fra.lng, fra.lat]]),
  distance_km: 6900, typical_duration_minutes: 520, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Strong backup via Turkish Airlines. DEL–IST routes west of the active advisory zone; IST–FRA is clean. Good frequency and hub depth.",
  ranking_context: "Ranks second: level-1 advisory on DEL–IST (same structural risk as direct), but the Istanbul connection adds schedule risk. Ranks ahead of Dubai because IST–FRA avoids the advisory zone entirely.",
  watch_for: "DEL–IST first leg routes west of the active Gulf advisory zone boundary. Level-1 advisory near the Gulf/Iran region. IST–FRA is clean over the Balkans.",
  explanation_bullets: [
    "DEL→IST first leg routes northwest skirting west of the active Gulf advisory zone — level-1 advisory, same structural category as Air India direct.",
    "IST→FRA second leg is clean — over the Balkans and central Europe with no advisory zone involvement.",
    "Turkish Airlines operates 2 daily DEL–IST departures, giving solid same-day rebooking options.",
    "Istanbul (IST) is Europe's largest hub by connecting routes — strong onward FRA frequency.",
    "Adds approximately 1 hour versus direct due to IST connection geometry."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · 2 daily DEL–DXB · DXB–FRA daily",
  path_geojson: line.([[del.lng, del.lat], [dxb.lng, dxb.lat], [30.0, 37.0], [fra.lng, fra.lat]]),
  distance_km: 7400, typical_duration_minutes: 560, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates option. DEL→DXB first leg is clean, but DXB→FRA crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below direct and Istanbul options due to advisory zone transit on DXB→FRA. Emirates' frequency and DXB hub depth are operational advantages but don't offset the airspace risk.",
  watch_for: "DXB→FRA second leg crosses the active Middle East advisory zone. Emirates provides the deepest rebooking options at DXB — best recovery path if disruption occurs post-departure.",
  explanation_bullets: [
    "DEL→DXB first leg routes west over the Arabian Sea — no advisory zone involvement on this leg.",
    "DXB→FRA second leg crosses the active Middle East advisory zone. This is the primary risk differentiating it from direct and Istanbul routing.",
    "Emirates offers 2 daily DEL–DXB departures — the highest frequency of the three options, useful for same-day rebooking.",
    "Dubai (DXB) has maintained continuous operations throughout the current conflict period; hub closure risk is low but non-zero.",
    "Total journey approximately 9.5 hours — longer than the direct and Istanbul options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Frankfurt (3 corridor families: central_asia/Direct, gulf_istanbul/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI → SINGAPORE
# Three families: direct · south_asia_bkk · south_asia_kul
# BOM→SIN is a high-volume pair. Clean corridor — all options avoid advisory zones.
# Differentiation is carrier depth, hub quality, and journey time.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Air India (AI) / IndiGo (6E) / Singapore Airlines (SQ) · Multiple daily BOM–SIN",
  path_geojson: line.([[bom.lng, bom.lat], [88.0, 10.0], [sin.lng, sin.lat]]),
  distance_km: 3950, typical_duration_minutes: 300, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best BOM→SIN option. Clean corridor with no advisory exposure. Singapore Airlines, Air India, and IndiGo all serve this pair with strong daily frequency.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, and the deepest carrier coverage of the three options. SQ adds premium optionality alongside AI/6E for budget flexibility.",
  watch_for: nil,
  explanation_bullets: [
    "BOM→SIN routes southeast over the Indian Ocean and Bay of Bengal — no advisory zone on this corridor.",
    "Singapore Airlines offers daily BOM–SIN service, giving premium options alongside Air India and IndiGo.",
    "At approximately 5 hours, disruption is typically manageable within the same day given multiple departures.",
    "Strong carrier competition on this route keeps pricing competitive — useful for outbound search comparison.",
    "No routing constraint or advisory concern applies to this corridor under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: sin.id, via_hub_city_id: bkk.id,
  corridor_family: "south_asia_bkk",
  route_name: "Via Bangkok",
  carrier_notes: "Thai Airways (TG) · BOM–BKK–SIN · daily BOM–BKK service",
  path_geojson: line.([[bom.lng, bom.lat], [85.0, 16.0], [bkk.lng, bkk.lat], [sin.lng, sin.lat]]),
  distance_km: 5050, typical_duration_minutes: 405, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Via Bangkok gives Thai Airways connectivity and a useful stop for those who want Southeast Asia flexibility. Both legs are clean.",
  ranking_context: "Ranks second: same clean airspace but the Bangkok connection adds schedule risk. Worth considering if you want to stop in Bangkok or if direct BOM–SIN is full.",
  watch_for: nil,
  explanation_bullets: [
    "BOM→BKK first leg routes northeast over the Bay of Bengal — no advisory zone involvement.",
    "BKK→SIN second leg is clean. Thai Airways connects these regularly with good frequency.",
    "Bangkok hub is useful if you need flexibility — high onward connectivity throughout Southeast Asia.",
    "Adds approximately 1.5 hours versus direct due to the Bangkok connection layover.",
    "Best used when direct BOM–SIN is sold out or when Bangkok is a desired intermediate stop."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: sin.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · BOM–KUL–SIN",
  path_geojson: line.([[bom.lng, bom.lat], [88.0, 8.0], [kul.lng, kul.lat], [sin.lng, sin.lat]]),
  distance_km: 4900, typical_duration_minutes: 395, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Both legs are clean and LCC pricing (AirAsia X) makes this the lowest-cost route when direct fares are high.",
  ranking_context: "Ranks third: same clean airspace but KUL is geographically close to SIN, making the overall routing longer per km than direct. Best used for price-sensitive travel.",
  watch_for: nil,
  explanation_bullets: [
    "BOM→KUL routes southeast over the Indian Ocean — clean corridor, no advisory zone.",
    "KUL→SIN is one of the world's busiest short-haul routes — extreme frequency across MH, AirAsia, and others.",
    "AirAsia X serves BOM–KUL with competitive budget fares. Useful when Air India or SQ direct pricing is high.",
    "Total journey approximately 6.5 hours — close to Bangkok routing but with KUL as a less prestigious transit hub.",
    "No advisory concern on either leg under current conditions."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Singapore (3 corridor families: direct, south_asia_bkk, south_asia_kul)")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI → BANGKOK
# Three families: direct · south_asia_sin · south_asia_kul
# BOM→BKK is a major high-volume pair. Clean corridor throughout.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Direct",
  carrier_notes: "Air India (AI) / IndiGo (6E) / Thai Airways (TG) · Multiple daily BOM–BKK",
  path_geojson: line.([[bom.lng, bom.lat], [86.0, 17.0], [bkk.lng, bkk.lat]]),
  distance_km: 2800, typical_duration_minutes: 210, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best BOM→BKK option. Clean corridor with no advisory exposure and multiple daily carriers. At under 3.5 hours, this is one of the simplest long-haul-adjacent routes to plan.",
  ranking_context: "Ranks first: no advisory exposure, direct routing, multiple carriers. Thai Airways, Air India, and IndiGo all serve this pair — strong daily frequency and rebooking options.",
  watch_for: nil,
  explanation_bullets: [
    "BOM→BKK routes northeast over the Bay of Bengal — no advisory zone involvement on this corridor.",
    "Multiple carriers including Thai Airways, Air India, and IndiGo provide strong frequency and competitive pricing.",
    "At approximately 3.5 hours, disruption is manageable on the same day given multiple departures throughout the day.",
    "Bangkok Suvarnabhumi (BKK) is Southeast Asia's most connected hub for onward connections beyond Thailand.",
    "No routing or advisory constraint applies under current conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: bkk.id, via_hub_city_id: sin.id,
  corridor_family: "south_asia_sin",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · BOM–SIN–BKK",
  path_geojson: line.([[bom.lng, bom.lat], [sin.lng, sin.lat], [bkk.lng, bkk.lat]]),
  distance_km: 5100, typical_duration_minutes: 415, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Via Singapore offers Singapore Airlines quality and Changi's world-class transit. Both legs clean. Best for premium travellers or when direct BOM–BKK is full.",
  ranking_context: "Ranks second: same clean airspace, but routing southeast then northwest adds significant journey time overhead. SIN hub score is strong but the geometry makes this inefficient for this pair.",
  watch_for: nil,
  explanation_bullets: [
    "BOM→SIN first leg routes southeast over the Indian Ocean — clean corridor.",
    "SIN→BKK second leg is clean. Singapore Airlines connects these with strong frequency.",
    "Singapore (SIN) is the world's best-connected Southeast Asian transit hub — strong recovery options if SIN–BKK is disrupted.",
    "Total journey approximately 7 hours — significantly longer than the 3.5-hour direct option due to southward geometry.",
    "Best for premium travellers who value SQ service quality or who want to use Changi Airport as an intermediate stop."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: bkk.id, via_hub_city_id: kul.id,
  corridor_family: "south_asia_kul",
  route_name: "Via Kuala Lumpur",
  carrier_notes: "Malaysia Airlines (MH) / AirAsia X (D7) · BOM–KUL–BKK",
  path_geojson: line.([[bom.lng, bom.lat], [88.0, 8.0], [kul.lng, kul.lat], [bkk.lng, bkk.lat]]),
  distance_km: 4900, typical_duration_minutes: 398, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 2, operational_score: 0,
  recommendation_text: "Budget option via Kuala Lumpur. Clean on both legs. Best when AirAsia X pricing undercuts the direct alternatives significantly.",
  ranking_context: "Ranks third: same clean airspace but the KUL routing takes you further south before heading north to Bangkok — geometrically inefficient. AirAsia X pricing is the main use case.",
  watch_for: nil,
  explanation_bullets: [
    "BOM→KUL routes southeast — clean corridor, no advisory zone involvement.",
    "KUL→BKK has good LCC frequency (AirAsia, Firefly). AirAsia X serves BOM–KUL competitively.",
    "Total journey approximately 6.5 hours — similar to the Singapore routing but KUL is a less premium transit experience.",
    "Best used when price is the primary consideration and direct or via-SIN options are expensive.",
    "No advisory concern on either leg under current conditions."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Bangkok (3 corridor families: direct, south_asia_sin, south_asia_kul)")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI → FRANKFURT
# Three families: direct_central_asia · gulf_istanbul · gulf_dubai
# Key India→Germany pair where airspace exposure differs between corridors.
# Air India's BOM→FRA uses Central Asian routing (airspace=1, avoid Gulf).
# Via Istanbul: west of Gulf advisory zone (airspace=1, IST→FRA clean).
# Via Dubai: DXB→FRA transits the active advisory zone (airspace=2).
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: fra.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air India (AI) · 1 daily BOM–FRA via Central Asian corridor",
  path_geojson: line.([[bom.lng, bom.lat], [62.0, 38.0], [44.0, 43.0], [fra.lng, fra.lat]]),
  distance_km: 6500, typical_duration_minutes: 490, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Best BOM→FRA option. Air India routes via Central Asian corridor — level-1 advisory only, no Gulf exposure. Direct routing eliminates connection risk.",
  ranking_context: "Ranks first: avoids the active Gulf advisory zone. Central Asian corridor carries a level-1 advisory but no active zone transit. Direct routing removes hub connection risk entirely.",
  watch_for: "Central Asian corridor carries a persistent level-1 advisory. Check Air India NOTAM status 48h before departure if flow restrictions are active on the Central Asian corridor.",
  explanation_bullets: [
    "BOM→FRA routes northwest via the Central Asian corridor — level-1 advisory, not through the active Gulf advisory zone.",
    "Air India operates this as a direct service with consistent routing since 2023. Single carrier means fewer rebooking options than a codeshare.",
    "Direct routing removes the risk of a Gulf hub connection during a period of regional advisory activity.",
    "Journey time approximately 8 hours. Frankfurt is Air India's primary German hub destination.",
    "Via-Istanbul (Turkish Airlines) is the best backup if Central Asian flow restrictions affect the Air India direct."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: fra.id, via_hub_city_id: ist.id,
  corridor_family: "gulf_istanbul",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily BOM–IST · IST–FRA multiple daily",
  path_geojson: line.([[bom.lng, bom.lat], [58.0, 34.0], [ist.lng, ist.lat], [fra.lng, fra.lat]]),
  distance_km: 7200, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Strong backup via Turkish Airlines. BOM–IST skirts west of the active advisory zone; IST–FRA is clean. Good hub depth and frequency.",
  ranking_context: "Ranks second: level-1 advisory on BOM–IST (same risk category as Air India direct), but IST hub connection adds schedule risk. Ranks ahead of Dubai because IST–FRA avoids the advisory zone.",
  watch_for: "BOM–IST first leg routes northwest, skirting the advisory zone boundary near the Gulf/Iran region. Level-1 advisory, same category as Air India direct. IST–FRA is clean.",
  explanation_bullets: [
    "BOM→IST routes northwest, staying west of the active Gulf advisory zone boundary — level-1 advisory, same structural category as Air India direct.",
    "IST→FRA second leg is clean — routes over the Balkans and central Europe with no advisory involvement.",
    "Turkish Airlines operates 2 daily BOM–IST departures, providing reliable same-day rebooking options if the first is disrupted.",
    "Istanbul is well-positioned between Mumbai and Frankfurt — limited geometry overhead versus direct.",
    "Adds approximately 1 hour versus direct. Worth considering when Air India is sold out."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: fra.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · Multiple daily BOM–DXB · DXB–FRA daily",
  path_geojson: line.([[bom.lng, bom.lat], [dxb.lng, dxb.lat], [30.0, 37.0], [fra.lng, fra.lat]]),
  distance_km: 7600, typical_duration_minutes: 575, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates option. BOM→DXB is clean, but DXB→FRA crosses the active Middle East advisory zone on the second leg.",
  ranking_context: "Ranked below direct and Istanbul due to advisory zone transit on DXB→FRA. Emirates' deep frequency at BOM–DXB is an operational advantage but doesn't offset the airspace risk differential.",
  watch_for: "DXB→FRA second leg crosses the active Middle East advisory zone. Emirates provides the deepest rebooking options at DXB if disruption occurs post-departure.",
  explanation_bullets: [
    "BOM→DXB first leg routes west over the Arabian Sea — no advisory zone involvement.",
    "DXB→FRA second leg crosses the active Middle East advisory zone. This is the key differentiator versus Air India direct and Turkish via IST.",
    "Emirates provides multiple daily BOM–DXB departures — the highest frequency of the three options. Useful for same-day rebooking.",
    "Dubai has maintained continuous operations throughout the current conflict period; hub access risk is low but non-zero.",
    "Total journey approximately 9.5 hours — longest of the three options due to southerly Gulf geometry."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Frankfurt (3 corridor families: central_asia/Direct, gulf_istanbul/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI → PARIS
# Three families: direct (central_asia) · turkey_hub · gulf_dubai
# Mirrors Paris → Delhi in structure; DEL departure. Iran FIR is the key variable.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: cdg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air India (AI) · 1 daily DEL–CDG; Air France (AF) · 1 daily DEL–CDG",
  path_geojson: line.([[del.lng, del.lat], [55.0, 38.0], [38.0, 45.0], [15.0, 50.0], [cdg.lng, cdg.lat]]),
  distance_km: 6590, typical_duration_minutes: 480, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for DEL→CDG. Air India and Air France both operate direct services via the Iran/Central Asian corridor. Level-1 advisory but no active Gulf transit.",
  ranking_context: "Ranks first because it avoids the active advisory zone on both the Gulf and India-facing approach. The Iran FIR carries a persistent level-1 advisory — worth monitoring, not avoiding at current severity.",
  watch_for: "DEL–CDG direct routes over Iran FIR (OIIX). Level-1 advisory in force. Iranian FIR closure would add 45–90 minutes via a southern detour.",
  explanation_bullets: [
    "DEL→CDG direct routes west via Afghanistan/Iran FIR then northwest over Caucasus/Eastern Europe.",
    "Iranian airspace carries a level-1 advisory — below the threshold that has triggered operational rerouting as of last review.",
    "Air India and Air France both operate direct services, providing dual-carrier flexibility.",
    "No connection eliminates the delay multiplier most relevant on this 8-hour journey."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: cdg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 4 daily DEL–IST · IST–CDG daily",
  path_geojson: line.([[del.lng, del.lat], [55.0, 35.0], [ist.lng, ist.lat], [cdg.lng, cdg.lat]]),
  distance_km: 7200, typical_duration_minutes: 545, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Highest frequency option. DEL–IST routes via Iran FIR (level-1); IST–CDG is clean. Turkish Airlines' 4 daily DEL–IST departures give the best same-day rebooking options.",
  ranking_context: "Ranked below direct due to connection overhead but above Dubai due to airspace preference on the second leg. TK frequency is the operational advantage.",
  watch_for: "DEL–IST first leg uses Iran/Afghanistan FIR — same level-1 advisory as the direct option. Istanbul is within monitoring range of regional tensions.",
  explanation_bullets: [
    "DEL→IST first leg routes via Iran/Afghanistan FIR — level-1 advisory, same as direct.",
    "IST→CDG is clean European routing — no advisory involvement.",
    "Turkish Airlines offers 4 daily DEL–IST departures, the highest frequency Delhi–Europe of any carrier."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · Multiple daily DEL–DXB · DXB–CDG daily",
  path_geojson: line.([[del.lng, del.lat], [dxb.lng, dxb.lat], [30.0, 37.0], [cdg.lng, cdg.lat]]),
  distance_km: 7500, typical_duration_minutes: 570, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High-frequency Emirates fallback. DEL→DXB is clean over the Arabian Sea; DXB→CDG crosses the active advisory zone on the second leg.",
  ranking_context: "Ranked below direct and Istanbul because DXB→CDG transits the active advisory zone. Emirates' frequency at DXB is unmatched — use when direct or IST options are unavailable.",
  watch_for: "DXB→CDG second leg transits the active Middle East advisory zone. DEL→DXB first leg is clean.",
  explanation_bullets: [
    "DEL→DXB first leg routes west over the Arabian Sea — no advisory zone involvement.",
    "DXB→CDG second leg crosses the active advisory zone — the key differentiator versus direct and IST options.",
    "Emirates provides 6+ daily DEL–DXB departures — the strongest first-leg frequency on this corridor."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Paris (3 corridor families: central_asia/Direct, turkey_hub/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI → AMSTERDAM
# Three families: direct (central_asia) · turkey_hub · gulf_dubai
# Mirrors Amsterdam → Mumbai. BOM departure; Iran FIR key differentiator.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: ams.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air India (AI) · 1 daily BOM–AMS; KLM (KL) · 1 daily BOM–AMS",
  path_geojson: line.([[bom.lng, bom.lat], [60.0, 32.0], [40.0, 42.0], [20.0, 50.0], [ams.lng, ams.lat]]),
  distance_km: 7190, typical_duration_minutes: 530, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for BOM→AMS. Direct services from Air India and KLM route via Iran/Central Asia (level-1 advisory) — cleaner than Gulf options that transit the active advisory zone.",
  ranking_context: "Ranks first: Iran FIR level-1 advisory is the operational constraint, but it does not trigger the same routing penalties as the active high-severity advisory zone. No connection overhead.",
  watch_for: "BOM–AMS direct routes via Iran FIR (OIIX). Level-1 advisory. Iranian FIR closure would require south detour via Oman/Saudi Arabia, adding ~60 minutes.",
  explanation_bullets: [
    "BOM→AMS routes northwest via Arabian Sea, Iran FIR, Caucasus — level-1 advisory on the Iran segment.",
    "Air India and KLM both operate direct BOM–AMS, providing carrier choice despite limited daily frequency.",
    "No connection removes the delay multiplier — significant advantage on a 9-hour journey."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: ams.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily BOM–IST · IST–AMS daily",
  path_geojson: line.([[bom.lng, bom.lat], [ist.lng, ist.lat], [ams.lng, ams.lat]]),
  distance_km: 7900, typical_duration_minutes: 595, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Clean second option via Istanbul. BOM–IST skirts the advisory zone boundary (level-1); IST–AMS is fully clean. Higher frequency than direct.",
  ranking_context: "Ranked below direct due to connection point, above Dubai due to better second-leg airspace. Turkish Airlines provides 2 daily BOM–IST departures.",
  watch_for: "BOM–IST first leg routes northwest, skirting the Gulf/Iran advisory zone boundary — level-1 advisory, same as direct.",
  explanation_bullets: [
    "BOM→IST routes northwest over the Arabian Sea/western India — level-1 advisory for the Iranian FIR segment.",
    "IST→AMS second leg is clean European routing.",
    "Turkish Airlines offers 2 daily BOM–IST departures with AMS connection — adds rebooking depth versus direct."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · Multiple daily BOM–DXB · DXB–AMS daily",
  path_geojson: line.([[bom.lng, bom.lat], [dxb.lng, dxb.lat], [30.0, 37.0], [ams.lng, ams.lat]]),
  distance_km: 7400, typical_duration_minutes: 565, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates fallback with highest frequency. BOM→DXB is clean; DXB→AMS crosses the active advisory zone. Use when direct and IST options are unavailable.",
  ranking_context: "Ranked below direct and IST because DXB→AMS transits the active advisory zone. Emirates' deep BOM–DXB frequency makes this the best contingency option.",
  watch_for: "DXB→AMS second leg transits the active Middle East advisory zone.",
  explanation_bullets: [
    "BOM→DXB routes over the Arabian Sea — no advisory involvement.",
    "DXB→AMS second leg crosses the active advisory zone — the key differentiator.",
    "Emirates provides the highest BOM–DXB frequency of any carrier on this corridor."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Amsterdam (3 corridor families: central_asia/Direct, turkey_hub/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI → PARIS
# Three families: direct (central_asia) · turkey_hub · gulf_dubai
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: cdg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Direct",
  carrier_notes: "Air India (AI) · 1 daily BOM–CDG; Air France (AF) · 1 daily BOM–CDG",
  path_geojson: line.([[bom.lng, bom.lat], [60.0, 32.0], [42.0, 42.0], [18.0, 50.0], [cdg.lng, cdg.lat]]),
  distance_km: 6990, typical_duration_minutes: 520, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for BOM→CDG. Direct via Iran/Central Asian corridor (level-1 advisory) — avoids the active Gulf advisory zone on the second leg entirely.",
  ranking_context: "Ranks first: Iran FIR level-1 does not currently drive operational rerouting. Direct routing avoids the active Gulf zone that penalises the Dubai option.",
  watch_for: "BOM–CDG direct routes via Iran FIR — level-1 advisory. Close Iranian FIR restriction would require detour adding ~60 minutes.",
  explanation_bullets: [
    "BOM→CDG direct routes via Arabian Sea, Iran FIR, Caucasus to Paris — no active Gulf advisory exposure.",
    "Air India and Air France both operate direct BOM–CDG services.",
    "Non-stop removes the largest delay risk on a 9.5-hour journey."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: cdg.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · 2 daily BOM–IST · IST–CDG multiple daily",
  path_geojson: line.([[bom.lng, bom.lat], [ist.lng, ist.lat], [cdg.lng, cdg.lat]]),
  distance_km: 7750, typical_duration_minutes: 590, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Frequency-backed alternative via Istanbul. BOM–IST skirts the Iran boundary (level-1); IST–CDG is clean. Turkish Airlines is the frequency leader on this approach.",
  ranking_context: "Ranked below direct due to connection point, above Dubai due to better second-leg airspace. TK frequency at BOM is the main operational advantage.",
  watch_for: "BOM–IST first leg routes northwest, skirting the Iran/Gulf advisory boundary — level-1.",
  explanation_bullets: [
    "BOM→IST routes northwest — skirts the advisory boundary but stays level-1.",
    "IST→CDG is fully clean European routing.",
    "Turkish Airlines offers 2 daily BOM–IST departures, providing the best non-Gulf recovery depth."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · Multiple daily BOM–DXB · DXB–CDG daily",
  path_geojson: line.([[bom.lng, bom.lat], [dxb.lng, dxb.lat], [28.0, 37.0], [cdg.lng, cdg.lat]]),
  distance_km: 7350, typical_duration_minutes: 560, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates' high-frequency option. BOM→DXB is clean; DXB→CDG crosses the active advisory zone. Best used when direct and IST options are sold out.",
  ranking_context: "Ranked third because DXB→CDG transits the active advisory zone. Emirates' BOM–DXB frequency remains the strongest operational contingency.",
  watch_for: "DXB→CDG second leg crosses the active advisory zone.",
  explanation_bullets: [
    "BOM→DXB routes cleanly over the Arabian Sea.",
    "DXB→CDG second leg transits the active Middle East advisory zone.",
    "Emirates' BOM–DXB frequency is the highest on any BOM–Europe routing — strongest contingency option."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Paris (3 corridor families: central_asia/Direct, turkey_hub/IST, gulf_dubai)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → SEOUL
# Three families: direct (central_asia) · via Istanbul · via HKG
# FRA→ICN: post-2022 routing via Central Asian corridor. No Gulf involvement.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Lufthansa Direct",
  carrier_notes: "Lufthansa (LH) · FRA–ICN direct · rerouted via Central Asian corridor since 2022",
  path_geojson: line.([[fra.lng, fra.lat], [50.0, 48.0], [82.0, 48.0], [icn.lng, icn.lat]]),
  distance_km: 9040, typical_duration_minutes: 680, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Fastest option when available. Lufthansa routes FRA–ICN via Central Asian corridor post-2022. No Gulf exposure. Verify current schedule — frequency has been reduced since the Russia rerouting.",
  ranking_context: "Ranks first on airspace and speed. Structural constraint is reduced frequency and sole dependence on the Central Asian corridor. Korean Air HKG option trades time for structural depth.",
  watch_for: "Entire route depends on Central Asian corridor. Lufthansa reduced FRA–ICN frequency post-2022 — verify current schedule. Check Eurocontrol ATFM for Central Asian routing status.",
  explanation_bullets: [
    "FRA–ICN now routes south of Russian airspace via Central Asian corridor — ~11.5h versus the pre-2022 ~10.5h polar route.",
    "No Gulf advisory zone involvement on either direction.",
    "Lufthansa reduced frequency on this route post-2022. Corridor resilience score 2/3 reflects limited alternatives if the Central Asian corridor closes."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: icn.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · FRA–IST–ICN, 1 daily",
  path_geojson: line.([[fra.lng, fra.lat], [ist.lng, ist.lat], [62.0, 42.0], [icn.lng, icn.lat]]),
  distance_km: 10100, typical_duration_minutes: 775, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Reliable alternative when direct is unavailable. FRA–IST is clean; IST–ICN routes via Central Asia (level-1 advisory). Turkish Airlines provides daily connectivity.",
  ranking_context: "Ranked below direct on time and corridor score, but provides structural depth when Lufthansa frequency is constrained. IST hub adds same-day rebooking options.",
  watch_for: "IST–ICN second leg routes via Central Asian corridor — level-1 advisory. Journey adds ~2h versus direct.",
  explanation_bullets: [
    "FRA–IST first leg is clean — no advisory zone involvement.",
    "IST→ICN routes via Central Asian corridor — same level-1 airspace advisory as the direct option.",
    "Turkish Airlines provides daily FRA–IST–ICN service with rebooking options at IST."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) / Korean Air (KE) — FRA–HKG–ICN",
  path_geojson: line.([[fra.lng, fra.lat], [50.0, 48.0], [82.0, 44.0], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 11100, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Two-stop option via Hong Kong. Adds journey time but gives you two world-class hubs and the highest total rebooking depth. Use when direct frequency is constrained.",
  ranking_context: "Ranked third due to two-connection complexity. Airspace is equivalent to direct — both use Central Asian corridor. HKG hub quality is high but the geometry overhead is significant.",
  watch_for: "FRA–HKG uses the Central Asian corridor. HKG–ICN is a 3-hour clean hop. Two connections create double connection risk — allow adequate layover at HKG.",
  explanation_bullets: [
    "FRA→HKG routes via Central Asian corridor — same airspace profile as direct FRA→ICN.",
    "HKG→ICN is a clean 3-hour segment over the South China Sea.",
    "Cathay Pacific and Korean Air both operate this pairing, providing strong frequency at both connection points."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Seoul (3 corridor families: central_asia/Direct, turkey_hub/IST, north_asia_hkg)")

# ─────────────────────────────────────────────────────────────────────────────
# AMSTERDAM → SEOUL
# Three families: direct (central_asia) · via Istanbul · via HKG
# AMS→ICN: limited direct options; KLM operates via Central Asia post-2022.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "KLM Direct",
  carrier_notes: "KLM (KL) · AMS–ICN direct · Central Asian corridor post-2022",
  path_geojson: line.([[ams.lng, ams.lat], [48.0, 50.0], [80.0, 48.0], [icn.lng, icn.lat]]),
  distance_km: 8900, typical_duration_minutes: 670, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best option for AMS→ICN. KLM's direct service via Central Asian corridor is the fastest and avoids Gulf advisory exposure. No connection risk.",
  ranking_context: "Ranks first on time and airspace. Corridor resilience 2/3 because single corridor dependency — if Central Asian corridor closes, no direct option exists. KLM frequency is limited; verify schedule.",
  watch_for: "AMS–ICN depends on Central Asian corridor. KLM frequency limited — verify current schedule before booking.",
  explanation_bullets: [
    "KLM operates direct AMS–ICN via Central Asian corridor post-2022, adding ~45 minutes versus pre-2022 polar routing.",
    "No Gulf advisory zone involvement on either direction.",
    "Sole carrier on direct routing — limited rebooking options if disrupted; consider via IST or HKG as backup."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: icn.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · AMS–IST–ICN, multiple daily AMS–IST",
  path_geojson: line.([[ams.lng, ams.lat], [ist.lng, ist.lat], [62.0, 42.0], [icn.lng, icn.lat]]),
  distance_km: 9800, typical_duration_minutes: 755, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Reliable backup via Istanbul. AMS–IST is clean; IST–ICN routes via Central Asia (level-1). Turkish Airlines provides high AMS–IST frequency for robust same-day rebooking.",
  ranking_context: "Second choice — AMS has among the highest TK frequency in Europe, making IST the most accessible hub fallback on this corridor.",
  watch_for: "IST–ICN second leg routes via Central Asian corridor — level-1 advisory.",
  explanation_bullets: [
    "AMS–IST first leg is clean European routing.",
    "IST→ICN routes via Central Asian corridor — level-1 advisory.",
    "Turkish Airlines provides multiple daily AMS–IST flights — the strongest backup frequency to Schiphol."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) / Korean Air (KE) — AMS–HKG–ICN",
  path_geojson: line.([[ams.lng, ams.lat], [48.0, 50.0], [82.0, 44.0], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 10800, typical_duration_minutes: 825, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Two-hub alternative with strong recovery depth. Adds journey time but Cathay's AMS–HKG service provides world-class frequency and the HKG–ICN hop is clean.",
  ranking_context: "Ranked third on complexity overhead. Airspace profile is equivalent to direct. Use when KLM and TK options are fully booked.",
  watch_for: "AMS–HKG uses Central Asian corridor. HKG–ICN is a clean 3-hour segment.",
  explanation_bullets: [
    "AMS→HKG routes via Central Asian corridor — same airspace risk profile as direct AMS→ICN.",
    "HKG→ICN is a clean 3-hour hop with high Cathay/KE frequency.",
    "Two connections at HKG create double connection risk — allow sufficient layover time."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Seoul (3 corridor families: central_asia/Direct, turkey_hub/IST, north_asia_hkg)")

# ─────────────────────────────────────────────────────────────────────────────
# PARIS → SEOUL
# Three families: direct (central_asia) · via Istanbul · via HKG
# CDG→ICN: Air France direct; Turkish via IST; Cathay via HKG.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Air France Direct",
  carrier_notes: "Air France (AF) · CDG–ICN direct · Central Asian corridor post-2022",
  path_geojson: line.([[cdg.lng, cdg.lat], [48.0, 50.0], [80.0, 47.0], [icn.lng, icn.lat]]),
  distance_km: 9100, typical_duration_minutes: 685, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Best for CDG→ICN. Air France direct via Central Asian corridor — no Gulf exposure. Slightly longer post-2022 than pre-Russia-rerouting polar path.",
  ranking_context: "Ranks first on airspace and time. Corridor dependency is the structural constraint. Air France frequency on this route is limited — verify schedule.",
  watch_for: "CDG–ICN depends on Central Asian corridor post-2022. Air France operates limited daily frequency — verify schedule.",
  explanation_bullets: [
    "Air France operates CDG–ICN direct via Central Asian corridor — adds ~45 min versus pre-2022 polar routing.",
    "No Gulf advisory zone involvement on either direction.",
    "Limited daily frequency from Air France — Korean Air KE/Air France codeshare options expand your choices."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: icn.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · CDG–IST–ICN, daily CDG–IST",
  path_geojson: line.([[cdg.lng, cdg.lat], [ist.lng, ist.lat], [62.0, 42.0], [icn.lng, icn.lat]]),
  distance_km: 9900, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Reliable alternative via Turkish Airlines. CDG–IST is clean; IST–ICN uses the Central Asian corridor. Adds frequency depth when Air France is sold out.",
  ranking_context: "Second choice — clean airspace on both legs, with the connection overhead as the only disadvantage versus direct.",
  watch_for: "IST–ICN second leg routes via Central Asian corridor — level-1 advisory.",
  explanation_bullets: [
    "CDG–IST first leg is clean European routing.",
    "IST→ICN routes via Central Asia — level-1 advisory, no Gulf exposure.",
    "Turkish Airlines provides daily CDG–IST service with ICN onward connections."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) / Air France (AF) + CX — CDG–HKG–ICN",
  path_geojson: line.([[cdg.lng, cdg.lat], [48.0, 50.0], [82.0, 44.0], [hkg.lng, hkg.lat], [icn.lng, icn.lat]]),
  distance_km: 11100, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 2, operational_score: 0,
  recommendation_text: "Two-hub route via Hong Kong. Adds journey time but Cathay's CDG–HKG service is among the best-quality long-haul products. Use when direct and IST are unavailable.",
  ranking_context: "Ranked third on complexity. Cathay Pacific provides excellent CDG–HKG frequency and the HKG–ICN hop is short and clean.",
  watch_for: "CDG–HKG uses Central Asian corridor. HKG–ICN is a clean 3-hour segment.",
  explanation_bullets: [
    "CDG→HKG routes via Central Asian corridor — same airspace category as direct.",
    "HKG→ICN is a clean 3-hour hop over the South China Sea.",
    "Cathay Pacific's CDG–HKG service provides strong frequency and world-class connection depth at HKG."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Seoul (3 corridor families: central_asia/Direct, turkey_hub/IST, north_asia_hkg)")

# ─────────────────────────────────────────────────────────────────────────────
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
# LONDON ↔ DUBAI
# Two families each direction: northern routing (Turkey/Iraq FIR) · southern routing (Egypt/Saudi FIR)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "iran_iraq_direct",
  route_name: "Northern Routing via Turkey/Iraq FIR",
  carrier_notes: "Emirates (EK) · daily LHR–DXB non-stop; British Airways (BA) · daily LHR–DXB; Virgin Atlantic (VS) · LHR–DXB",
  path_geojson: line.([[lhr.lng, lhr.lat], [15.0, 45.0], [28.0, 38.0], [42.0, 34.0], [dxb.lng, dxb.lat]]),
  distance_km: 5500, typical_duration_minutes: 385, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The dominant LHR–DXB routing transits the Balkans, Turkey, and Iraq FIR before entering UAE airspace. Emirates, British Airways, and Virgin Atlantic all operate this corridor. It crosses the ICAO Middle East advisory zone and skirts Iranian FIR boundaries — operationally reliable today but carries elevated airspace exposure versus the southern alternative. Preferred on time; monitor before departure when regional tensions are elevated.",
  ranking_context: "Fastest LHR–DXB routing at ~6.4h. Carries airspace_score 2 due to Middle East advisory zone transit and proximity to Iranian FIR. Ranked above southern routing on time alone; southern routing is preferred when advisory notices are active.",
  watch_for: "Monitor EASA and UK CAA Ops Bulletins for Iraq FIR (ORBB) and Iranian FIR (OIIX) activity. During periods of elevated regional tension this routing has seen temporary height and lateral restrictions imposed on short notice.",
  explanation_bullets: [
    "Crosses the Balkans and Turkey before entering Iraq FIR (ORBB) — all three carriers file this routing as standard.",
    "Transits the ICAO-designated Middle East advisory zone: elevated airspace exposure score versus the southern alternative.",
    "Skirts Iranian FIR (OIIX) on the final descent into UAE airspace — distance from IRI border is manageable but notable.",
    "Fastest geometry (~6.4h, ~5,500 km); when EASA or UK CAA bulletins are clear this remains the preferred option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "egypt_saudi_direct",
  route_name: "Southern Routing via Mediterranean/Egypt/Saudi FIR",
  carrier_notes: "Flydubai (FZ) · LHR–DXB via southern FIR path; charter and ad-hoc routings",
  path_geojson: line.([[lhr.lng, lhr.lat], [0.0, 38.0], [20.0, 32.0], [35.0, 27.0], [dxb.lng, dxb.lat]]),
  distance_km: 5700, typical_duration_minutes: 400, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 2,
  recommendation_text: "Southern alternative that routes down the Mediterranean, across North Africa via Egypt FIR, then through Saudi FIR and Red Sea approach into UAE. Adds roughly 15–20 minutes versus the northern routing but meaningfully reduces advisory-zone exposure: it stays south of the Iraq FIR and well clear of Iranian airspace. Flydubai and ad-hoc charter operators frequently file this path. Preferred when EASA or UK CAA bulletins flag elevated Iraq or Iran advisory notices.",
  ranking_context: "Ranked below northern routing on time (+~15 min, ~5,700 km) but scores better on airspace exposure. Corridor_score 1 reflects slightly higher coordination demand across the Egypt and Saudi FIRs compared with a purely domestic European departure. Operational_score 2 reflects that this path is filed primarily by Flydubai and charter/ad-hoc operators, not the high-frequency mainline carriers.",
  watch_for: "Egypt FIR (HECC) and Saudi FIR (OEJD) are operationally stable; Libya FIR (HLLL) to the west is avoided on this path. Monitor Saudi FIR NOTAMs during major religious events when FIR capacity can tighten.",
  explanation_bullets: [
    "Routes south over the Mediterranean and then east across Egypt FIR — avoids Iraq FIR and Iranian FIR entirely.",
    "Red Sea approach into UAE keeps the aircraft well clear of the ICAO Middle East advisory zone core.",
    "Adds ~15–20 minutes over the northern routing; a worthwhile trade when advisory notices are active.",
    "Flydubai and charter operators regularly file this FIR path; Egyptian and Saudi ATC coordination is routine."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Dubai (2 corridor families: iran_iraq_direct/northern, egypt_saudi_direct/southern)")

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "iran_iraq_direct",
  route_name: "Northern Routing via Iraq/Turkey FIR",
  carrier_notes: "Emirates (EK) · daily DXB–LHR non-stop; British Airways (BA) · daily DXB–LHR; Virgin Atlantic (VS) · DXB–LHR",
  path_geojson: line.([[dxb.lng, dxb.lat], [42.0, 34.0], [28.0, 38.0], [15.0, 45.0], [lhr.lng, lhr.lat]]),
  distance_km: 5500, typical_duration_minutes: 415, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Standard DXB–LHR westbound routing transiting Iraq FIR (ORBB) and Turkey before entering European airspace. Emirates, British Airways, and Virgin Atlantic all operate this corridor as their primary filing. Crosses the ICAO Middle East advisory zone and remains proximate to the Iranian FIR on departure from UAE. Fastest option at ~6.9h westbound; monitor EASA and UK CAA Ops Bulletins before departure when regional advisories are active.",
  ranking_context: "Fastest DXB–LHR routing at ~6.9h westbound. Airspace_score 2 reflects Middle East advisory zone transit and Iranian FIR proximity on departure. Ranked above southern routing on time; southern routing is preferred when Iraq or Iran advisory notices are elevated.",
  watch_for: "Departure from DXB initially skirts Iranian FIR (OIIX) before transitioning into Iraq FIR (ORBB). Monitor EASA and UK CAA Ops Bulletins. During heightened regional tensions, altitude and lateral restrictions on ORBB have been imposed with short notice.",
  explanation_bullets: [
    "Departs DXB northwestbound, initially proximate to Iranian FIR (OIIX) — standard but worth monitoring when IRI tensions are elevated.",
    "Transits Iraq FIR (ORBB) — crosses the ICAO Middle East advisory zone; airspace_score 2.",
    "Continues through Turkey and Balkans into European airspace — remainder of route is advisory-clean.",
    "Fastest DXB–LHR geometry (~6.9h westbound, ~5,500 km); preferred when advisory bulletins are clear."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "egypt_saudi_direct",
  route_name: "Southern Routing via Saudi/Egypt FIR",
  carrier_notes: "Flydubai (FZ) · DXB–LHR via southern FIR path; charter and ad-hoc routings",
  path_geojson: line.([[dxb.lng, dxb.lat], [35.0, 27.0], [20.0, 32.0], [0.0, 38.0], [lhr.lng, lhr.lat]]),
  distance_km: 5700, typical_duration_minutes: 430, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 2,
  recommendation_text: "Southern DXB–LHR alternative routing northwest through Saudi FIR, Red Sea, Egypt FIR, and Mediterranean before entering Europe. Avoids Iraq FIR and stays well clear of Iranian airspace. Adds ~15–20 minutes versus the northern routing but substantially reduces Middle East advisory-zone exposure. Preferred when EASA or UK CAA bulletins flag elevated Iraq or Iran advisory notices.",
  ranking_context: "Ranked below northern routing on time (+~15 min, ~5,700 km) but significantly cleaner on airspace exposure. Corridor_score 1 reflects the coordination burden across Saudi and Egypt FIRs on departure. Operational_score 2 reflects that this path is filed primarily by Flydubai and charter/ad-hoc operators — limited rebooking depth versus the mainline northern routing.",
  watch_for: "Saudi FIR (OEJD) and Egypt FIR (HECC) are operationally stable. Monitor Saudi NOTAMs during major religious events. Libya FIR (HLLL) west of the track is avoided on this path.",
  explanation_bullets: [
    "Departs DXB northwest through Saudi FIR and Red Sea — avoids Iranian FIR entirely on departure.",
    "Routes across Egypt FIR and Mediterranean — stays well clear of Iraq FIR and the ICAO Middle East advisory zone core.",
    "Adds ~15–20 minutes over northern routing; a worthwhile trade when Iraq/Iran advisory notices are elevated.",
    "Saudi and Egyptian ATC coordination is routine for this path; Flydubai and charter operators file it regularly."
  ],
  calculated_at: now
})

IO.puts("  ✓ Dubai → London (2 corridor families: iran_iraq_direct/northern, egypt_saudi_direct/southern)")

# ─────────────────────────────────────────────────────────────────────────────
# DUBAI ↔ SINGAPORE
# Two families each direction: direct subcontinent · south India/Sri Lanka approach
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "direct_subcont",
  route_name: "Via South India Direct",
  carrier_notes: "Emirates (EK) · daily DXB–SIN non-stop; Singapore Airlines (SQ) · DXB–SIN non-stop",
  path_geojson: line.([[dxb.lng, dxb.lat], [63.0, 22.0], [72.0, 20.0], [80.0, 12.0], [90.0, 8.0], [sin.lng, sin.lat]]),
  distance_km: 5850, typical_duration_minutes: 420, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The cleanest DXB–SIN routing. Departs east over the Arabian Sea and Indian Ocean, crossing the Indian subcontinent south of the Himalayan FIRs, then transiting the Bay of Bengal and Andaman Sea into Singapore FIR. Completely avoids all advisory zones — no Middle East exposure, no Central Asian FIRs, no Russian airspace. Emirates and Singapore Airlines both operate this corridor as non-stop service. The preferred routing under all advisory conditions.",
  ranking_context: "Primary DXB–SIN routing. Airspace_score 0 reflects a fully advisory-clean path — no ICAO advisory zones, no EASA notices, no NOTAM-flagged segments. Fastest and cleanest option.",
  watch_for: "No material advisory concerns on this routing. Indian FIR (VABB/VIDP) coordination is standard. Monitor Chennai FIR (VOMF) and Kolkata FIR (VECF) NOTAMs for convective activity during monsoon season.",
  explanation_bullets: [
    "Eastbound departure from DXB over Arabian Sea — immediately clears all advisory zone exposure on departure.",
    "Tracks across the Indian subcontinent over Indian Ocean FIRs — all operationally clean with no EASA notices.",
    "Bay of Bengal and Andaman Sea transit into Singapore FIR is fully advisory-clean.",
    "Emirates and Singapore Airlines non-stop service; the preferred routing under all conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: sin.id, via_hub_city_id: nil,
  corridor_family: "south_india_route",
  route_name: "Via Southern India/Sri Lanka Approach",
  carrier_notes: "Some Emirates (EK) seasonal filings; Batik Air (OD) · DXB–SIN routings",
  path_geojson: line.([[dxb.lng, dxb.lat], [63.0, 22.0], [72.0, 15.0], [80.0, 8.0], [90.0, 5.0], [sin.lng, sin.lat]]),
  distance_km: 5900, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "A slightly more southerly DXB–SIN variant that tracks further south over the Indian peninsula and Sri Lanka FIR before crossing the Bay of Bengal into Singapore. Operationally equivalent to the direct subcontinent routing in terms of advisory-zone clearance — airspace_score 0 on both. This FIR path is used by some seasonal or charter filings. Adds roughly 10–15 minutes versus the direct subcontinent route.",
  ranking_context: "Equivalent advisory-zone clearance to the direct_subcont routing; ranked second on time alone (+~15 min, ~5,900 km). Both routings are fully advisory-clean.",
  watch_for: "Colombo FIR (VCCC) and Chennai FIR (VOMF) coordination is routine. Monitor Bay of Bengal convective NOTAMs during southwest monsoon season (June–September).",
  explanation_bullets: [
    "Routes further south over the Indian peninsula versus the direct subcontinent path — equivalent advisory clearance.",
    "Sri Lanka FIR (VCCC) transit is operationally clean and well-coordinated.",
    "Bay of Bengal crossing into Singapore FIR follows a slightly more southerly track — both are advisory-clean.",
    "Adds ~10–15 minutes versus direct subcontinent routing; used by some seasonal and charter filings."
  ],
  calculated_at: now
})

IO.puts("  ✓ Dubai → Singapore (2 corridor families: direct_subcont, south_india_route)")

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "direct_subcont",
  route_name: "Via South India Direct",
  carrier_notes: "Emirates (EK) · daily SIN–DXB non-stop; Singapore Airlines (SQ) · SIN–DXB non-stop",
  path_geojson: line.([[sin.lng, sin.lat], [90.0, 8.0], [80.0, 12.0], [72.0, 20.0], [63.0, 22.0], [dxb.lng, dxb.lat]]),
  distance_km: 5850, typical_duration_minutes: 430, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The cleanest SIN–DXB routing. Departs northwest across the Andaman Sea and Bay of Bengal, tracks across the Indian subcontinent, and arrives into DXB from the east. Completely avoids all advisory zones throughout — no Middle East advisory exposure, no Central Asian FIRs, no Russian airspace. Emirates and Singapore Airlines operate this non-stop. The preferred routing under all advisory conditions.",
  ranking_context: "Primary SIN–DXB routing. Airspace_score 0 reflects a fully advisory-clean path on all segments. Fastest and cleanest option.",
  watch_for: "No material advisory concerns on this routing. Monitor Indian FIR NOTAMs for convective activity during monsoon season. Arabian Sea approach into DXB is routine.",
  explanation_bullets: [
    "Departs SIN northwest — Andaman Sea and Bay of Bengal transit are fully advisory-clean.",
    "Indian subcontinent crossing via Indian FIRs is operationally standard with no EASA notices.",
    "Arrives DXB from the east, clear of Iranian FIR and Middle East advisory zones throughout.",
    "Emirates and Singapore Airlines non-stop service; preferred routing under all advisory conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "south_india_route",
  route_name: "Via Southern India/Sri Lanka Approach",
  carrier_notes: "Some Emirates (EK) seasonal filings; Batik Air (OD) · SIN–DXB routings",
  path_geojson: line.([[sin.lng, sin.lat], [90.0, 5.0], [80.0, 8.0], [72.0, 15.0], [63.0, 22.0], [dxb.lng, dxb.lat]]),
  distance_km: 5900, typical_duration_minutes: 445, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Southerly SIN–DXB variant routing further south over Sri Lanka FIR and southern Indian peninsula before crossing the Arabian Sea into UAE. Operationally equivalent to the direct subcontinent routing in advisory clearance. Used by some seasonal and charter filings. Adds roughly 10–15 minutes versus the primary routing.",
  ranking_context: "Equivalent advisory-zone clearance to the direct_subcont routing; ranked second on time alone (+~15 min). Both routings are fully advisory-clean.",
  watch_for: "Colombo FIR (VCCC) is operationally clean. Monitor Bay of Bengal and Arabian Sea convective NOTAMs during monsoon seasons.",
  explanation_bullets: [
    "Departs SIN on a more southwesterly track — routes via Sri Lanka FIR, equally advisory-clean.",
    "Southern Indian peninsula crossing via Chennai FIR (VOMF) is operationally routine.",
    "Arabian Sea transit and DXB arrival from the east avoids Iranian FIR and advisory zones entirely.",
    "Adds ~10–15 minutes versus direct subcontinent; used by some seasonal and charter operators."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Dubai (2 corridor families: direct_subcont, south_india_route)")

# ─────────────────────────────────────────────────────────────────────────────
# DELHI ↔ TOKYO
# Three families each direction: central_asia direct · via Hong Kong · via Singapore
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asia Direct",
  carrier_notes: "Air India (AI) · DEL–NRT non-stop; Japan Airlines (JL) · DEL–NRT; ANA · DEL–NRT",
  path_geojson: line.([[del.lng, del.lat], [70.0, 38.0], [90.0, 43.0], [115.0, 35.0], [nrt.lng, nrt.lat]]),
  distance_km: 5850, typical_duration_minutes: 430, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary DEL–NRT routing tracks north over Pakistan and Kazakhstan before crossing Central Asia into China FIR and then Japan. Air India, JAL, and ANA all operate direct service on this corridor. The route carries airspace_score 1 due to Central Asian corridor congestion and the Iranian FIR proximity on the western segment near departure — the initial climb out of DEL briefly approaches the IRI/PAK FIR boundary. When Central Asian FIR advisories are stable this is the fastest option.",
  ranking_context: "Fastest DEL–NRT routing at ~7.2h. Airspace_score 1 for Central Asian FIR congestion and Iranian FIR proximity near DEL departure. Ranked above HKG and SIN alternatives on time; southern routings preferred when Central Asian advisories are elevated.",
  watch_for: "Monitor EASA notices for Kazakhstan FIR (UAAA) and Uzbekistan FIR (UTTT). Initial departure from DEL briefly approaches the Iran/Pakistan FIR boundary — verify current IRI advisory status. Central Asian FIR coordination can tighten when Russian airspace rerouting adds traffic.",
  explanation_bullets: [
    "Northbound departure from DEL crosses Pakistan FIR and approaches the Iranian FIR boundary — airspace_score 1 on this western segment.",
    "Central Asian FIRs (Kazakhstan, Uzbekistan) are EASA-monitored — open but require pre-departure advisory check.",
    "China FIR (ZBPE/ZGZU) and Japan FIR (RJAA) transit is advisory-clean and operationally standard.",
    "Air India, JAL, and ANA all serve DEL–NRT direct on this routing — fastest geometry (~7.2h, ~5,850 km)."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · DEL–HKG–NRT connection",
  path_geojson: line.([[del.lng, del.lat], [95.0, 25.0], [108.0, 20.0], [hkg.lng, hkg.lat], [nrt.lng, nrt.lat]]),
  distance_km: 6400, typical_duration_minutes: 510, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Advisory-clean DEL–NRT routing via Hong Kong. The DEL–HKG leg routes southeast over Myanmar and the Bay of Bengal then northeast into South China Sea — avoids Central Asian FIRs entirely. The HKG–NRT leg is advisory-clean over the East China Sea. Cathay Pacific provides strong DEL–HKG connectivity with onward NRT service. Preferred when Central Asian FIR advisories are elevated. Adds ~1.3h versus the Central Asia direct.",
  ranking_context: "Ranked second for DEL–NRT at ~8.5h total. Airspace_score 0 — fully advisory-clean. Corridor_score 1 for South China Sea single-path dependence. Complexity_score 1 for the transit stop at HKG.",
  watch_for: "DEL–HKG–NRT is fully advisory-clean. Monitor HKG transit time; Cathay Pacific's DEL–HKG schedule should allow adequate connection time for NRT onward flight.",
  explanation_bullets: [
    "DEL–HKG leg routes southeast over Myanmar and Bay of Bengal — completely avoids Central Asian FIRs.",
    "South China Sea transit into HKG is advisory-clean; airspace_score 0 throughout.",
    "HKG–NRT leg tracks northeast over East China Sea — also fully advisory-clean.",
    "Cathay Pacific provides reliable DEL–HKG connections; adds ~1.3h over Central Asia direct."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: nrt.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · DEL–SIN–NRT connection",
  path_geojson: line.([[del.lng, del.lat], [sin.lng, sin.lat], [nrt.lng, nrt.lat]]),
  distance_km: 7800, typical_duration_minutes: 610, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Fully advisory-clean DEL–NRT routing via Singapore. The DEL–SIN leg routes south over the Indian subcontinent, entirely avoiding Central Asian FIRs. The SIN–NRT leg tracks northeast through Southeast Asian FIRs and the South China Sea — also fully clean. Singapore Airlines operates both legs. Longest routing at ~10.2h total; preferred when both Central Asian advisories and northern South China Sea routing are elevated.",
  ranking_context: "Ranked third for DEL–NRT at ~10.2h total. Airspace_score 0 — fully advisory-clean. Corridor_score 2 reflects single-path dependence on the SIN corridor for the second leg.",
  watch_for: "DEL–SIN–NRT is fully advisory-clean. Adds approximately 3 hours versus Central Asia direct. Singapore Airlines frequency on both legs is high; connection times at SIN are generally comfortable.",
  explanation_bullets: [
    "DEL–SIN leg routes south over the Indian subcontinent — fully avoids Central Asian FIRs.",
    "SIN–NRT leg tracks northeast through Southeast Asian and South China Sea FIRs — advisory-clean throughout.",
    "Singapore Airlines provides strong frequency on both legs with reliable SIN connections.",
    "Longest DEL–NRT routing (~10.2h, ~7,800 km); preferred when Central Asian and northern alternatives carry elevated advisories."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Tokyo (3 corridor families: central_asia, north_asia_hkg/HKG, southeast_asia/SIN)")

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asia Direct",
  carrier_notes: "Air India (AI) · NRT–DEL non-stop; Japan Airlines (JL) · NRT–DEL; ANA · NRT–DEL",
  path_geojson: line.([[nrt.lng, nrt.lat], [115.0, 35.0], [90.0, 43.0], [70.0, 38.0], [del.lng, del.lat]]),
  distance_km: 5850, typical_duration_minutes: 440, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary NRT–DEL routing tracks westbound across China and Central Asian FIRs before descending into India. Air India, JAL, and ANA all operate direct service. Airspace_score 1 for Central Asian FIR congestion and Iranian FIR proximity on the western segment as the aircraft approaches DEL. When Central Asian FIR advisories are stable this is the fastest option at ~7.3h.",
  ranking_context: "Fastest NRT–DEL routing at ~7.3h. Airspace_score 1 for Central Asian FIR congestion and Iranian FIR proximity near DEL arrival. Ranked above HKG and SIN alternatives on time.",
  watch_for: "Monitor EASA notices for Kazakhstan FIR (UAAA) and Uzbekistan FIR (UTTT). Approach into DEL from the northwest briefly approaches the Iran/Pakistan FIR boundary — verify IRI advisory status. Central Asian FIR congestion can increase when Russian airspace rerouting diverts traffic.",
  explanation_bullets: [
    "Westbound track from NRT across China FIR into Central Asian FIRs — EASA-monitored but operationally open.",
    "Western segment approaching DEL passes near Iranian FIR boundary — airspace_score 1.",
    "Air India, JAL, and ANA direct service on this corridor; fastest NRT–DEL geometry (~7.3h).",
    "Preferred routing when Central Asian advisory bulletins are clear."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: del.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · NRT–HKG–DEL connection",
  path_geojson: line.([[nrt.lng, nrt.lat], [hkg.lng, hkg.lat], [108.0, 20.0], [95.0, 25.0], [del.lng, del.lat]]),
  distance_km: 6400, typical_duration_minutes: 520, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Advisory-clean NRT–DEL routing via Hong Kong. The NRT–HKG leg tracks southwest over the East China Sea — advisory-clean. The HKG–DEL leg routes northwest over the South China Sea and Myanmar, avoiding Central Asian FIRs. Cathay Pacific provides reliable NRT–HKG–DEL connections. Preferred when Central Asian advisories are elevated. Adds ~1.3h versus the Central Asia direct.",
  ranking_context: "Ranked second for NRT–DEL at ~8.7h total. Airspace_score 0 — fully advisory-clean. Corridor_score 1 for South China Sea path. Complexity_score 1 for the transit stop at HKG.",
  watch_for: "NRT–HKG–DEL is fully advisory-clean. Verify Cathay Pacific HKG–DEL schedule for adequate connection time after the NRT–HKG leg.",
  explanation_bullets: [
    "NRT–HKG leg tracks southwest over East China Sea — fully advisory-clean.",
    "HKG–DEL leg routes via South China Sea and Myanmar, avoiding Central Asian FIRs entirely.",
    "Cathay Pacific provides strong NRT–HKG connections with reliable DEL onward service.",
    "Adds ~1.3h over Central Asia direct but fully advisory-clean on both segments."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: del.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · NRT–SIN–DEL connection",
  path_geojson: line.([[nrt.lng, nrt.lat], [sin.lng, sin.lat], [del.lng, del.lat]]),
  distance_km: 7800, typical_duration_minutes: 620, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Fully advisory-clean NRT–DEL routing via Singapore. The NRT–SIN leg routes south through Southeast Asian FIRs — clean throughout. The SIN–DEL leg tracks northwest over the Indian subcontinent. Singapore Airlines operates both legs. Longest routing at ~10.3h; preferred when both Central Asian advisories and northern alternatives carry elevated notices.",
  ranking_context: "Ranked third for NRT–DEL at ~10.3h total. Airspace_score 0 — fully advisory-clean. Corridor_score 2 reflects single-path dependence on the SIN corridor.",
  watch_for: "NRT–SIN–DEL is fully advisory-clean. Adds approximately 3 hours versus Central Asia direct. Singapore Airlines SIN hub provides reliable connections on both legs.",
  explanation_bullets: [
    "NRT–SIN leg routes south through Southeast Asian FIRs — fully advisory-clean throughout.",
    "SIN–DEL leg tracks northwest over the Indian subcontinent — avoids Central Asian FIRs entirely.",
    "Singapore Airlines provides high frequency on both legs with reliable SIN hub connections.",
    "Longest NRT–DEL routing (~10.3h, ~7,800 km); chosen when Central Asian advisories are elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Delhi (3 corridor families: central_asia, north_asia_hkg/HKG, southeast_asia/SIN)")

# ─────────────────────────────────────────────────────────────────────────────
# MUMBAI ↔ SEOUL
# Two families each direction: direct sea (southern) · central Asia (northern)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "direct_sea",
  route_name: "Via Bay of Bengal / South China Sea",
  carrier_notes: "Air India (AI) · BOM–ICN non-stop; Korean Air (KE) · BOM–ICN; Asiana (OZ) · BOM–ICN",
  path_geojson: line.([[bom.lng, bom.lat], [80.0, 12.0], [95.0, 10.0], [108.0, 15.0], [122.0, 28.0], [icn.lng, icn.lat]]),
  distance_km: 5050, typical_duration_minutes: 410, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary BOM–ICN routing tracks east across the Indian subcontinent, Bay of Bengal, and Southeast Asian FIRs before crossing the South China Sea and East China Sea into Korea. Air India, Korean Air, and Asiana all operate direct service. Completely avoids all advisory zones — no Middle East exposure, no Central Asian FIRs, no Iranian FIR proximity. Airspace_score 0 throughout. Fastest and cleanest option.",
  ranking_context: "Primary BOM–ICN routing. Airspace_score 0 — fully advisory-clean. Faster than the northern Central Asia routing (~6.8h vs ~6.5h) and with substantially better airspace exposure. This is the preferred routing under all advisory conditions.",
  watch_for: "No material advisory concerns on this routing. Monitor Bay of Bengal convective NOTAMs during monsoon season. South China Sea FIR coordination is standard.",
  explanation_bullets: [
    "Eastbound departure from BOM over the Indian subcontinent — immediately clears all advisory zone exposure.",
    "Bay of Bengal and Southeast Asian FIR transit is fully advisory-clean with no EASA notices.",
    "South China Sea and East China Sea crossing into Korea is operationally standard — advisory-clean.",
    "Air India, Korean Air, and Asiana direct service; preferred routing under all conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asia Northern Route",
  carrier_notes: "Some Air India (AI) seasonal filings; ad-hoc charter routings",
  path_geojson: line.([[bom.lng, bom.lat], [65.0, 30.0], [75.0, 40.0], [95.0, 42.0], [115.0, 38.0], [icn.lng, icn.lat]]),
  distance_km: 4800, typical_duration_minutes: 390, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Northern BOM–ICN routing over Pakistan, Central Asian FIRs, and China. Geometrically shorter (~4,800 km vs ~5,050 km) but carries airspace_score 1 due to Central Asian corridor congestion and Iranian FIR proximity on the western segment near BOM departure. The advisory-clean southern routing via Bay of Bengal is preferred in most cases — this northern path is only advantageous when Central Asian FIR advisories are clear and the time saving is operationally meaningful.",
  ranking_context: "Ranked second for BOM–ICN. Geometrically shorter but airspace_score 1 versus the southern route's 0. The southern Bay of Bengal routing is preferred for its clean advisory profile. This northern path is used when Central Asian advisories are verified clear.",
  watch_for: "Monitor EASA notices for Kazakhstan FIR (UAAA) and Pakistan FIR (OPKR). Initial departure from BOM northbound approaches the Iranian FIR boundary — verify IRI advisory status. Central Asian corridor congestion can increase when Russian airspace rerouting adds traffic.",
  explanation_bullets: [
    "Northbound departure from BOM crosses Pakistan FIR and approaches the Iranian FIR boundary — airspace_score 1.",
    "Central Asian FIRs (Kazakhstan/Uzbekistan) are EASA-monitored — open but require pre-departure advisory verification.",
    "Geometrically shorter (~4,800 km, ~6.5h) but advisory exposure makes the southern routing preferable in most conditions.",
    "Some Air India seasonal filings use this path; verify current Central Asian advisory status before departure."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Seoul (2 corridor families: direct_sea/Bay of Bengal, central_asia/northern)")

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "direct_sea",
  route_name: "Via South China Sea / Bay of Bengal",
  carrier_notes: "Air India (AI) · ICN–BOM non-stop; Korean Air (KE) · ICN–BOM; Asiana (OZ) · ICN–BOM",
  path_geojson: line.([[icn.lng, icn.lat], [122.0, 28.0], [108.0, 15.0], [95.0, 10.0], [80.0, 12.0], [bom.lng, bom.lat]]),
  distance_km: 5050, typical_duration_minutes: 420, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary ICN–BOM routing tracks southwest over the East China Sea, South China Sea, and Southeast Asian FIRs before crossing the Bay of Bengal into India. Completely avoids all advisory zones throughout. Air India, Korean Air, and Asiana all operate direct service. Airspace_score 0 on all segments. The preferred routing under all advisory conditions.",
  ranking_context: "Primary ICN–BOM routing. Airspace_score 0 — fully advisory-clean. Preferred over the northern Central Asia routing for its clean advisory profile.",
  watch_for: "No material advisory concerns on this routing. Monitor Bay of Bengal convective NOTAMs during monsoon season. South China Sea FIR coordination is standard.",
  explanation_bullets: [
    "Southwestbound from ICN over East China Sea — fully advisory-clean on departure.",
    "South China Sea and Southeast Asian FIR transit avoids all ICAO advisory zones.",
    "Bay of Bengal and Indian subcontinent approach into BOM is operationally standard.",
    "Air India, Korean Air, and Asiana direct service; preferred routing under all conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asia Northern Route",
  carrier_notes: "Some Air India (AI) seasonal filings; ad-hoc charter routings",
  path_geojson: line.([[icn.lng, icn.lat], [115.0, 38.0], [95.0, 42.0], [75.0, 40.0], [65.0, 30.0], [bom.lng, bom.lat]]),
  distance_km: 4800, typical_duration_minutes: 400, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Northern ICN–BOM routing over China and Central Asian FIRs before descending into India. Geometrically shorter but carries airspace_score 1 due to Central Asian corridor congestion and Iranian FIR proximity on the final western descent into BOM. The southern routing via South China Sea and Bay of Bengal is preferred for its clean advisory profile.",
  ranking_context: "Ranked second for ICN–BOM. Geometrically shorter but airspace_score 1 versus the southern route's 0. Southern routing is preferred under most advisory conditions.",
  watch_for: "Monitor Kazakhstan FIR (UAAA) and Pakistan FIR (OPKR) EASA notices. Approach into BOM from the northwest crosses near the Iranian FIR boundary — verify IRI advisory status.",
  explanation_bullets: [
    "Western descent from Central Asian FIRs into BOM approaches the Iran/Pakistan FIR boundary — airspace_score 1.",
    "Central Asian FIRs (Kazakhstan, Uzbekistan) are EASA-monitored — require pre-departure advisory verification.",
    "Geometrically shorter (~4,800 km, ~6.7h) but advisory exposure makes the southern routing preferable.",
    "Some Air India seasonal filings; verify Central Asian advisory status before departure."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Mumbai (2 corridor families: direct_sea/South China Sea, central_asia/northern)")

# ─────────────────────────────────────────────────────────────────────────────
# KUALA LUMPUR ↔ SEOUL
# Two families each direction: direct South China Sea · Philippines approach
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "direct_sea",
  route_name: "Via South China Sea Direct",
  carrier_notes: "Malaysia Airlines (MH) · KUL–ICN non-stop; Korean Air (KE) · KUL–ICN; AirAsia X (D7) · KUL–ICN",
  path_geojson: line.([[kul.lng, kul.lat], [108.0, 15.0], [120.0, 25.0], [icn.lng, icn.lat]]),
  distance_km: 4700, typical_duration_minutes: 380, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary KUL–ICN routing tracks northeast over the South China Sea into Korean airspace. Malaysia Airlines, Korean Air, and AirAsia X all operate this corridor as their standard filing. Completely avoids all advisory zones throughout — no Middle East exposure, no Central Asian FIRs, no Russian airspace involvement. Airspace_score 0 on all segments. The fastest and cleanest option under all advisory conditions.",
  ranking_context: "Primary KUL–ICN routing. Airspace_score 0 — fully advisory-clean. Fastest option at ~6.3h. No advisory concerns on any segment.",
  watch_for: "No material advisory concerns on this routing. South China Sea FIR coordination (ZGZU/RPHI) is operationally standard. Monitor convective NOTAMs during typhoon season (June–November).",
  explanation_bullets: [
    "Northeastbound departure from KUL over South China Sea — fully advisory-clean from takeoff.",
    "South China Sea FIR transit is operationally standard with no ICAO advisory zone involvement.",
    "East China Sea approach into ICN is clean and well-coordinated.",
    "Malaysia Airlines, Korean Air, and AirAsia X all file this standard routing — preferred under all conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: kul.id, destination_city_id: icn.id, via_hub_city_id: nil,
  corridor_family: "philippines_route",
  route_name: "Via Philippines Approach",
  carrier_notes: "Some Malaysia Airlines (MH) and Philippine Airlines (PR) seasonal filings",
  path_geojson: line.([[kul.lng, kul.lat], [110.0, 8.0], [120.0, 14.0], [125.0, 25.0], [icn.lng, icn.lat]]),
  distance_km: 4750, typical_duration_minutes: 390, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Alternative KUL–ICN routing that takes a slightly more easterly track through Philippine FIR airspace before continuing northeast to Korea. Operationally equivalent to the direct South China Sea routing in advisory-zone clearance — airspace_score 0 on both. This FIR path is used by some seasonal filings from Malaysia Airlines and Philippine Airlines. Adds roughly 10 minutes versus the primary routing.",
  ranking_context: "Equivalent advisory-zone clearance to the direct_sea routing; ranked second on time alone (+~10 min, ~4,750 km). Both routings are fully advisory-clean.",
  watch_for: "Philippines FIR (RPHI) is operationally clean. Monitor Luzon FIR convective NOTAMs during typhoon season. South China Sea east of the Philippines is advisory-clean.",
  explanation_bullets: [
    "Slightly more easterly track through Philippine FIR — equally clean from an advisory standpoint.",
    "Philippines FIR (RPHI) coordination is standard; no advisory zone involvement on this path.",
    "Northeast continuation from Philippines into Korean airspace is advisory-clean throughout.",
    "Adds ~10 minutes versus the primary South China Sea routing; used by some seasonal filings."
  ],
  calculated_at: now
})

IO.puts("  ✓ Kuala Lumpur → Seoul (2 corridor families: direct_sea/South China Sea, philippines_route)")

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: kul.id, via_hub_city_id: nil,
  corridor_family: "direct_sea",
  route_name: "Via South China Sea Direct",
  carrier_notes: "Malaysia Airlines (MH) · ICN–KUL non-stop; Korean Air (KE) · ICN–KUL; AirAsia X (D7) · ICN–KUL",
  path_geojson: line.([[icn.lng, icn.lat], [120.0, 25.0], [108.0, 15.0], [kul.lng, kul.lat]]),
  distance_km: 4700, typical_duration_minutes: 390, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary ICN–KUL routing tracks southwest over the East China Sea and South China Sea into Malaysia. Malaysia Airlines, Korean Air, and AirAsia X all operate this corridor as their standard filing. Completely avoids all advisory zones throughout. Airspace_score 0 on all segments. The fastest and cleanest option under all advisory conditions.",
  ranking_context: "Primary ICN–KUL routing. Airspace_score 0 — fully advisory-clean. Fastest option at ~6.5h. No advisory concerns on any segment.",
  watch_for: "No material advisory concerns on this routing. South China Sea FIR coordination is operationally standard. Monitor typhoon-season convective NOTAMs (June–November).",
  explanation_bullets: [
    "Southwestbound from ICN over East China Sea — fully advisory-clean on departure.",
    "South China Sea FIR transit avoids all ICAO advisory zones — no EASA notices apply.",
    "Approach into KUL from the northeast is operationally standard.",
    "Malaysia Airlines, Korean Air, and AirAsia X direct service; preferred routing under all conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: kul.id, via_hub_city_id: nil,
  corridor_family: "philippines_route",
  route_name: "Via Philippines Approach",
  carrier_notes: "Some Malaysia Airlines (MH) and Philippine Airlines (PR) seasonal filings",
  path_geojson: line.([[icn.lng, icn.lat], [125.0, 25.0], [120.0, 14.0], [110.0, 8.0], [kul.lng, kul.lat]]),
  distance_km: 4750, typical_duration_minutes: 400, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Alternative ICN–KUL routing that tracks through Philippine FIR airspace on the southbound leg before continuing to Malaysia. Operationally equivalent to the direct South China Sea routing in advisory clearance — airspace_score 0 on both. Adds roughly 10 minutes versus the primary routing.",
  ranking_context: "Equivalent advisory-zone clearance to the direct_sea routing; ranked second on time alone (+~10 min, ~4,750 km). Both routings are fully advisory-clean.",
  watch_for: "Philippines FIR (RPHI) is operationally clean. Monitor convective NOTAMs during typhoon season (June–November).",
  explanation_bullets: [
    "Southwestbound from ICN takes a slightly more easterly track through Philippine FIR — advisory-clean.",
    "Philippines FIR coordination is standard; no advisory zone involvement.",
    "Continues southwest from Philippines into Malaysian airspace — advisory-clean throughout.",
    "Adds ~10 minutes versus primary South China Sea routing; some seasonal filings use this FIR path."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Kuala Lumpur (2 corridor families: direct_sea/South China Sea, philippines_route)")

# ─────────────────────────────────────────────────────────────────────────────
# DUBAI ↔ BANGKOK
# Two families each direction: direct subcontinent · south India route
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "direct_subcont",
  route_name: "Via South Asia Direct",
  carrier_notes: "Emirates (EK) · daily DXB–BKK non-stop; Thai Airways (TG) · DXB–BKK non-stop",
  path_geojson: line.([[dxb.lng, dxb.lat], [63.0, 22.0], [72.0, 20.0], [80.0, 16.0], [92.0, 14.0], [bkk.lng, bkk.lat]]),
  distance_km: 5000, typical_duration_minutes: 380, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary DXB–BKK routing departs east over the Arabian Sea, crosses the Indian subcontinent south of the Himalayan FIRs, and enters Thailand via Myanmar FIR and Bangkok FIR. Emirates and Thai Airways both operate non-stop service. Completely avoids all advisory zones — no Middle East exposure after departure, no Central Asian FIRs, no Iranian FIR involvement. Airspace_score 0 throughout. The preferred routing under all advisory conditions.",
  ranking_context: "Primary DXB–BKK routing. Airspace_score 0 — fully advisory-clean. Fastest option at ~6.3h. No advisory concerns on any segment.",
  watch_for: "No material advisory concerns on this routing. Monitor Indian FIR NOTAMs for convective activity during monsoon season. Myanmar FIR (VYYY) and Bangkok FIR (VTBB) coordination is operationally standard.",
  explanation_bullets: [
    "Eastbound departure from DXB over Arabian Sea — immediately clears all Middle East advisory zone exposure.",
    "Indian subcontinent crossing via Indian Ocean FIRs is fully advisory-clean with no EASA notices.",
    "Myanmar FIR and Bangkok FIR transit is operationally standard and advisory-clean.",
    "Emirates and Thai Airways non-stop service; preferred routing under all advisory conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: bkk.id, via_hub_city_id: nil,
  corridor_family: "south_india_route",
  route_name: "Via Southern India",
  carrier_notes: "Some Emirates (EK) seasonal filings; charter and ad-hoc routings",
  path_geojson: line.([[dxb.lng, dxb.lat], [63.0, 20.0], [72.0, 14.0], [80.0, 10.0], [92.0, 10.0], [bkk.lng, bkk.lat]]),
  distance_km: 5100, typical_duration_minutes: 395, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Southerly DXB–BKK variant that routes further south over the tip of the Indian peninsula and Sri Lanka before entering the Bay of Bengal and crossing into Thailand. Operationally equivalent to the direct subcontinent routing in advisory clearance — airspace_score 0 on both. Used by some seasonal Emirates filings and charter operators. Adds roughly 10–15 minutes versus the primary routing.",
  ranking_context: "Equivalent advisory-zone clearance to the direct_subcont routing; ranked second on time alone (+~15 min, ~5,100 km). Both routings are fully advisory-clean.",
  watch_for: "Colombo FIR (VCCC) and Chennai FIR (VOMF) coordination is routine. Monitor Bay of Bengal convective NOTAMs during southwest monsoon season (June–September).",
  explanation_bullets: [
    "More southerly track over the Indian peninsula than the primary routing — equally advisory-clean.",
    "Sri Lanka FIR (VCCC) and southern Indian FIR transit is operationally standard.",
    "Bay of Bengal crossing into Myanmar and Thailand FIRs is advisory-clean throughout.",
    "Adds ~10–15 minutes versus direct subcontinent routing; used by some seasonal and charter filings."
  ],
  calculated_at: now
})

IO.puts("  ✓ Dubai → Bangkok (2 corridor families: direct_subcont, south_india_route)")

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "direct_subcont",
  route_name: "Via South Asia Direct",
  carrier_notes: "Emirates (EK) · daily BKK–DXB non-stop; Thai Airways (TG) · BKK–DXB non-stop",
  path_geojson: line.([[bkk.lng, bkk.lat], [92.0, 14.0], [80.0, 16.0], [72.0, 20.0], [63.0, 22.0], [dxb.lng, dxb.lat]]),
  distance_km: 5000, typical_duration_minutes: 390, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The primary BKK–DXB routing departs west over Myanmar FIR and the Indian subcontinent before crossing the Arabian Sea into UAE. Completely avoids all advisory zones throughout. Emirates and Thai Airways both operate non-stop service. Airspace_score 0 on all segments. The preferred routing under all advisory conditions.",
  ranking_context: "Primary BKK–DXB routing. Airspace_score 0 — fully advisory-clean. Fastest option at ~6.5h. No advisory concerns on any segment.",
  watch_for: "No material advisory concerns on this routing. Monitor Indian FIR NOTAMs for monsoon convective activity. Arabian Sea approach into DXB from the east avoids Iranian FIR and Middle East advisory zones entirely.",
  explanation_bullets: [
    "Westbound departure from BKK over Myanmar FIR — advisory-clean from takeoff.",
    "Indian subcontinent crossing is fully advisory-clean with no EASA notices.",
    "Arabian Sea transit and DXB arrival from the east avoids Iranian FIR and all advisory zones.",
    "Emirates and Thai Airways non-stop service; preferred routing under all advisory conditions."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "south_india_route",
  route_name: "Via Southern India",
  carrier_notes: "Some Emirates (EK) seasonal filings; charter and ad-hoc routings",
  path_geojson: line.([[bkk.lng, bkk.lat], [92.0, 10.0], [80.0, 10.0], [72.0, 14.0], [63.0, 20.0], [dxb.lng, dxb.lat]]),
  distance_km: 5100, typical_duration_minutes: 405, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Southerly BKK–DXB variant routing further south over the Bay of Bengal and southern Indian peninsula before crossing the Arabian Sea into UAE. Operationally equivalent to the direct subcontinent routing in advisory clearance — airspace_score 0 on both. Used by some seasonal filings and charter operators. Adds roughly 10–15 minutes versus the primary routing.",
  ranking_context: "Equivalent advisory-zone clearance to the direct_subcont routing; ranked second on time alone (+~15 min, ~5,100 km). Both routings are fully advisory-clean.",
  watch_for: "Colombo FIR (VCCC) and Chennai FIR (VOMF) coordination is routine. Monitor Bay of Bengal convective NOTAMs during monsoon season.",
  explanation_bullets: [
    "More southerly westbound track over the Bay of Bengal than the primary routing — equally advisory-clean.",
    "Southern Indian peninsula crossing via Sri Lanka FIR is operationally standard.",
    "Arabian Sea approach into DXB from the southeast avoids Iranian FIR and all advisory zones.",
    "Adds ~10–15 minutes versus direct subcontinent; used by some seasonal and charter operators."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Dubai (2 corridor families: direct_subcont, south_india_route)")

# ─────────────────────────────────────────────────────────────────────────────
# DUBAI ↔ MUMBAI
# Two families each direction: Arabian Sea direct · overland via Pakistan FIR
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "arabian_sea_direct",
  route_name: "Arabian Sea Direct",
  carrier_notes: "Emirates (EK) · DXB–BOM daily; Air India (AI) · DXB–BOM; IndiGo (6E) · DXB–BOM",
  path_geojson: line.([[dxb.lng, dxb.lat], [60.0, 22.0], [68.0, 19.0], [bom.lng, bom.lat]]),
  distance_km: 1920, typical_duration_minutes: 200, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Primary DXB–BOM routing tracks southeast over the Arabian Sea, entering Indian airspace well south of Pakistan. Airspace_score 0 — avoids all advisory zones including Iranian FIR, Pakistani FIR, and Gulf conflict zones. Emirates, Air India, and IndiGo all operate this as one of the highest-frequency Gulf–India corridors. At ~1,920 km and ~3h20m this is a short, high-frequency, advisory-clean hop.",
  ranking_context: "Top-ranked DXB–BOM routing. Airspace_score 0 — fully advisory-clean. Corridor is short and saturated with capacity; lowest-risk option on all measures.",
  watch_for: "Arabian Sea track is advisory-clean under all current conditions. Monitor Mumbai NOTAM (VABB FIR) for monsoon convective activity May–September which can add minor delays. No airspace advisory concerns.",
  explanation_bullets: [
    "Southeast track from DXB over the Arabian Sea enters India south of Pakistan FIR — airspace_score 0.",
    "Avoids Iranian FIR entirely; route is well south of any Gulf advisory zone.",
    "Emirates, Air India, and IndiGo provide very high-frequency coverage on this corridor.",
    "Shortest DXB–India routing at ~1,920 km; monsoon convection (May–Sep) is the only operational variable."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: bom.id, via_hub_city_id: nil,
  corridor_family: "overland_pak",
  route_name: "Overland via Pakistan FIR",
  carrier_notes: "Some Air India (AI) and IndiGo (6E) seasonal filings via northern track",
  path_geojson: line.([[dxb.lng, dxb.lat], [58.0, 25.0], [65.0, 27.0], [68.0, 24.0], [bom.lng, bom.lat]]),
  distance_km: 1980, typical_duration_minutes: 210, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Northern DXB–BOM variant tracking over Oman FIR and into Pakistan FIR before descending into India. Airspace_score 1 for Pakistan FIR (OPKR) transit. Most scheduled operators prefer the Arabian Sea southern track; this routing is used by some seasonal and ad-hoc filings. Marginally shorter geometry but carries higher advisory risk.",
  ranking_context: "Ranked second for DXB–BOM. Airspace_score 1 for Pakistan FIR. Arabian Sea direct is preferred under all normal conditions.",
  watch_for: "Pakistan FIR (OPKR) — EASA maintains flight restriction advisories for portions of Pakistani airspace. Verify OPKR NOTAMs and current EASA/UK CAA guidance before using this track.",
  explanation_bullets: [
    "Northern track transits Pakistan FIR (OPKR) — airspace_score 1; EASA advisories apply.",
    "Arabian Sea direct routing avoids Pakistan FIR entirely and is the standard industry choice.",
    "Distance difference is marginal (~60 km); advisory risk difference is significant.",
    "Some seasonal Air India and IndiGo filings use this track; Emirates uses Arabian Sea."
  ],
  calculated_at: now
})

IO.puts("  ✓ Dubai → Mumbai (2 corridor families: arabian_sea_direct, overland_pak)")

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "arabian_sea_direct",
  route_name: "Arabian Sea Direct",
  carrier_notes: "Emirates (EK) · BOM–DXB daily; Air India (AI) · BOM–DXB; IndiGo (6E) · BOM–DXB",
  path_geojson: line.([[bom.lng, bom.lat], [68.0, 19.0], [60.0, 22.0], [dxb.lng, dxb.lat]]),
  distance_km: 1920, typical_duration_minutes: 195, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Standard BOM–DXB routing northwest over the Arabian Sea. Airspace_score 0 — avoids all advisory zones including Iranian FIR and Pakistani FIR. One of the highest-frequency Gulf–South Asia corridors globally, with Emirates, Air India, and IndiGo all operating multiple daily rotations. Fully advisory-clean in all normal conditions.",
  ranking_context: "Top-ranked BOM–DXB routing. Airspace_score 0 — fully advisory-clean. Highest-frequency corridor choice; no advisory concerns.",
  watch_for: "Arabian Sea track is advisory-clean. Mumbai monsoon convective NOTAMs (May–September) may add minor ground delays at VABB. No airspace advisory concerns on this routing.",
  explanation_bullets: [
    "Northwest track from BOM into Arabian Sea avoids Pakistan FIR entirely — airspace_score 0.",
    "Iranian FIR is well north of this routing; no Gulf advisory zones affected.",
    "Emirates, Air India, IndiGo provide the highest flight frequencies of any DXB corridor.",
    "Monsoon season (May–Sep) can create approach delays at BOM; airspace remains clean."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bom.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "overland_pak",
  route_name: "Overland via Pakistan FIR",
  carrier_notes: "Occasional seasonal filings; not the primary industry routing",
  path_geojson: line.([[bom.lng, bom.lat], [68.0, 24.0], [65.0, 27.0], [58.0, 25.0], [dxb.lng, dxb.lat]]),
  distance_km: 1980, typical_duration_minutes: 205, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Northern BOM–DXB variant routing over Pakistan FIR and into Oman before reaching UAE. Airspace_score 1 for Pakistan FIR (OPKR) transit. The standard industry choice is the Arabian Sea southern track. Advisory risk from Pakistan FIR is meaningful relative to the minimal time savings on this short corridor.",
  ranking_context: "Ranked second for BOM–DXB. Airspace_score 1 for Pakistan FIR. Arabian Sea direct is the clear first choice under all normal conditions.",
  watch_for: "Pakistan FIR (OPKR) — EASA and UK CAA maintain advisories; verify current status before routing via this track. Arabian Sea direct is the operationally preferred alternative.",
  explanation_bullets: [
    "Northern overland track transits Pakistan FIR (OPKR) — airspace_score 1.",
    "Arabian Sea routing avoids Pakistan FIR and is used by the vast majority of scheduled operators.",
    "Marginal distance difference does not justify additional advisory risk on this short corridor.",
    "Seasonal ad-hoc filings may use this track; Emirates and mainstream carriers use Arabian Sea."
  ],
  calculated_at: now
})

IO.puts("  ✓ Mumbai → Dubai (2 corridor families: arabian_sea_direct, overland_pak)")

# ─────────────────────────────────────────────────────────────────────────────
# DUBAI ↔ DELHI
# Two families each direction: overland via Pakistan FIR (primary) · Arabian Sea southern contingency
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "overland_pak",
  route_name: "Overland via Pakistan FIR",
  carrier_notes: "Emirates (EK) · DXB–DEL multiple daily; Air India (AI) · DXB–DEL; IndiGo (6E) · DXB–DEL",
  path_geojson: line.([[dxb.lng, dxb.lat], [58.0, 25.0], [65.0, 28.0], [70.0, 29.0], [del.lng, del.lat]]),
  distance_km: 2190, typical_duration_minutes: 215, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Primary DXB–DEL routing tracks northeast over Oman FIR, through Pakistan FIR, and into Rajasthan FIR before Delhi. Airspace_score 1 for Pakistan FIR (OPKR) transit. Despite the advisory flag, this is the standard industry routing used by Emirates, Air India, and IndiGo for DXB–DEL. The OPKR crossing is narrow on this geometry and remains commercially operational — monitor for any advisory escalation.",
  ranking_context: "Primary DXB–DEL routing. Airspace_score 1 for Pakistan FIR; ranked first on time and frequency despite the advisory. Arabian Sea alternative avoids OPKR but adds ~50 minutes.",
  watch_for: "Pakistan FIR (OPKR) — EASA and UK CAA maintain advisories; verify current status before departure. Monitor for any escalation in India–Pakistan tensions which could trigger immediate OPKR FIR restrictions.",
  explanation_bullets: [
    "Northeast track transits Pakistan FIR (OPKR) — airspace_score 1; verify EASA/UK CAA advisories.",
    "Pakistan FIR crossing is narrow on this geometry (~200 km); commercially operational despite advisory.",
    "Emirates, Air India, and IndiGo all use this routing for standard scheduled service.",
    "Monitor India–Pakistan geopolitical situation — escalation can trigger rapid OPKR closure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: dxb.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "arabian_sea_direct",
  route_name: "Arabian Sea Southern Route",
  carrier_notes: "Alternative filing used when Pakistan FIR advisories are elevated",
  path_geojson: line.([[dxb.lng, dxb.lat], [60.0, 22.0], [65.0, 20.0], [72.0, 20.0], [78.0, 25.0], [del.lng, del.lat]]),
  distance_km: 2560, typical_duration_minutes: 255, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Contingency DXB–DEL routing south over the Arabian Sea and across Gujarat before reaching Delhi. Airspace_score 0 — fully avoids Pakistan FIR by routing south of Karachi and entering India via Gujarat FIR. Corridor_score 1 as this track is longer and less frequency-rich. Used when Pakistan FIR advisories are elevated or OPKR access is restricted. Adds approximately 40–50 minutes versus the overland routing.",
  ranking_context: "Ranked second for DXB–DEL. Airspace_score 0 — fully advisory-clean. Preferred when Pakistan FIR is restricted; adds ~50 min versus overland.",
  watch_for: "Arabian Sea and Gujarat FIR transit is fully advisory-clean. This routing activates when OPKR is closed or advisory-restricted. Monitor India–Pakistan tensions and NOTAM issuance.",
  explanation_bullets: [
    "South over Arabian Sea and into Gujarat FIR — completely avoids Pakistan FIR; airspace_score 0.",
    "Longer geometry (~2,560 km vs ~2,190 km overland) adds ~40–50 minutes to the journey.",
    "Activated by airlines as contingency when Pakistan FIR advisories are elevated or OPKR restricted.",
    "India entry via Gujarat FIR is advisory-clean and operationally standard."
  ],
  calculated_at: now
})

IO.puts("  ✓ Dubai → Delhi (2 corridor families: overland_pak/primary, arabian_sea_direct/contingency)")

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "overland_pak",
  route_name: "Overland via Pakistan FIR",
  carrier_notes: "Emirates (EK) · DEL–DXB multiple daily; Air India (AI) · DEL–DXB; IndiGo (6E) · DEL–DXB",
  path_geojson: line.([[del.lng, del.lat], [70.0, 29.0], [65.0, 28.0], [58.0, 25.0], [dxb.lng, dxb.lat]]),
  distance_km: 2190, typical_duration_minutes: 210, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Primary DEL–DXB routing southwest from Rajasthan FIR through Pakistan FIR and into Oman FIR before UAE. Airspace_score 1 for Pakistan FIR (OPKR) transit — the standard industry route for all major operators on this corridor. Emirates, Air India, and IndiGo all use this geometry. OPKR crossing is operationally normal under current conditions but warrants monitoring given EASA/UK CAA standing advisories.",
  ranking_context: "Primary DEL–DXB routing. Airspace_score 1 for Pakistan FIR; ranked first on time and operator availability. Arabian Sea alternative avoids OPKR but is ~50 min longer.",
  watch_for: "Pakistan FIR (OPKR) — verify current EASA and UK CAA advisory status. Monitor India–Pakistan geopolitical situation; escalation can trigger rapid airspace closure.",
  explanation_bullets: [
    "Southwest departure transits Pakistan FIR (OPKR) — airspace_score 1; monitor EASA advisories.",
    "Commercially standard routing; Emirates, Air India, IndiGo all operate via this track.",
    "Pakistan FIR crossing (~200 km) is operationally routine but geopolitically sensitive.",
    "Arabian Sea contingency routing available if OPKR is restricted — adds ~50 minutes."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "arabian_sea_direct",
  route_name: "Arabian Sea Southern Route",
  carrier_notes: "Contingency filing activated when Pakistan FIR advisories are elevated",
  path_geojson: line.([[del.lng, del.lat], [78.0, 25.0], [72.0, 20.0], [65.0, 20.0], [60.0, 22.0], [dxb.lng, dxb.lat]]),
  distance_km: 2560, typical_duration_minutes: 250, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Contingency DEL–DXB routing south from Delhi through Gujarat FIR, across the Arabian Sea south of Pakistan, into UAE. Airspace_score 0 — fully avoids Pakistan FIR. Corridor_score 1 for the longer geometry and lower scheduled frequency on this track. Preferred when OPKR (Pakistan FIR) is advisory-restricted or closed. Adds approximately 40–50 minutes versus the standard overland routing.",
  ranking_context: "Ranked second for DEL–DXB. Airspace_score 0 — fully advisory-clean. Recommended when Pakistan FIR advisories are elevated; adds ~50 min versus overland.",
  watch_for: "Arabian Sea and Gujarat FIR transit is advisory-clean. This routing activates when Pakistan FIR is restricted. Monitor OPKR advisory status and India–Pakistan geopolitical situation.",
  explanation_bullets: [
    "Southeast departure into Gujarat FIR then Arabian Sea — completely avoids Pakistan FIR; airspace_score 0.",
    "Longer geometry (~2,560 km vs ~2,190 km); adds ~40–50 minutes.",
    "Contingency choice activated by airlines when OPKR advisories are elevated or FIR is restricted.",
    "Gujarat and Arabian Sea airspace is fully advisory-clean with no current EASA/UK CAA notices."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Dubai (2 corridor families: overland_pak/primary, arabian_sea_direct/contingency)")

# ─────────────────────────────────────────────────────────────────────────────
# HONG KONG ↔ DELHI
# Two families each direction: Bay of Bengal (primary) · Central Asian corridor
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "south_asia_bay",
  route_name: "Via Bay of Bengal",
  carrier_notes: "Cathay Pacific (CX) · HKG–DEL non-stop; Air India (AI) · HKG–DEL; IndiGo (6E) · HKG–DEL",
  path_geojson: line.([[hkg.lng, hkg.lat], [108.0, 18.0], [95.0, 15.0], [85.0, 15.0], [80.0, 20.0], [del.lng, del.lat]]),
  distance_km: 3660, typical_duration_minutes: 310, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Primary HKG–DEL routing tracks southwest over the South China Sea, crosses Myanmar FIR, transits the Bay of Bengal, and enters India via eastern FIRs. Airspace_score 0 — avoids Central Asian FIRs, Iranian FIR, and Pakistani FIR entirely. Cathay Pacific, Air India, and IndiGo all operate non-stop on this corridor. Bay of Bengal routing is the standard industry choice under all advisory conditions.",
  ranking_context: "Top-ranked HKG–DEL routing. Airspace_score 0 — fully advisory-clean. Fastest and most-served option at ~5h10m; preferred under all conditions.",
  watch_for: "Myanmar FIR (VYYY) — generally advisory-clean for overflights; verify current NOTAM status. Bay of Bengal transit and India entry are fully advisory-clean.",
  explanation_bullets: [
    "Southwest track via South China Sea, Myanmar FIR, and Bay of Bengal — avoids Central Asian FIRs; airspace_score 0.",
    "Iranian FIR and Pakistani FIR are not transited on this routing.",
    "Cathay Pacific, Air India, IndiGo all operate non-stop HKG–DEL via this corridor.",
    "Myanmar FIR overflight is advisory-clean; Bay of Bengal and Indian FIR entry are standard."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: hkg.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asian Corridor",
  carrier_notes: "Occasional northern filings; not the primary industry routing",
  path_geojson: line.([[hkg.lng, hkg.lat], [105.0, 30.0], [90.0, 38.0], [75.0, 38.0], [del.lng, del.lat]]),
  distance_km: 3780, typical_duration_minutes: 330, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Northern HKG–DEL variant tracking northwest over China FIR, through Central Asian FIRs, and into Delhi. Airspace_score 1 for Central Asian FIR congestion and Iranian FIR proximity on the western approach. The Bay of Bengal direct is shorter, advisory-cleaner, and the industry standard — this northern routing only appears in exceptional filings.",
  ranking_context: "Ranked second for HKG–DEL. Airspace_score 1 for Central Asian FIRs; longer than Bay of Bengal direct. Bay of Bengal routing preferred under all normal conditions.",
  watch_for: "Central Asian FIRs (Kazakhstan UAAA, Uzbekistan UTTT) — EASA-monitored. Western approach to DEL may approach Pakistan FIR and Iranian FIR advisory areas.",
  explanation_bullets: [
    "Northern track over Central Asia transits Kazakhstan and Uzbekistan FIRs — airspace_score 1.",
    "Western approach to Delhi may bring routing close to Pakistan FIR and Iranian FIR advisory areas.",
    "Bay of Bengal routing is shorter, advisory-cleaner (airspace_score 0), and industry-standard.",
    "Central Asian routing only relevant if Bay of Bengal track has exceptional operational constraints."
  ],
  calculated_at: now
})

IO.puts("  ✓ Hong Kong → Delhi (2 corridor families: south_asia_bay/Bay of Bengal, central_asia/northern)")

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "south_asia_bay",
  route_name: "Via Bay of Bengal",
  carrier_notes: "Cathay Pacific (CX) · DEL–HKG non-stop; Air India (AI) · DEL–HKG; IndiGo (6E) · DEL–HKG",
  path_geojson: line.([[del.lng, del.lat], [80.0, 20.0], [85.0, 15.0], [95.0, 15.0], [108.0, 18.0], [hkg.lng, hkg.lat]]),
  distance_km: 3660, typical_duration_minutes: 315, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Primary DEL–HKG routing tracks southeast from Delhi, crossing the Bay of Bengal, Myanmar FIR, and South China Sea before reaching Hong Kong. Airspace_score 0 — completely avoids Iranian FIR, Pakistani FIR, and Central Asian FIRs. Cathay Pacific, Air India, and IndiGo operate non-stop service. The southeastern Bay of Bengal routing is the standard industry choice under all advisory conditions.",
  ranking_context: "Top-ranked DEL–HKG routing. Airspace_score 0 — fully advisory-clean. Industry-standard at ~5h15m non-stop.",
  watch_for: "Myanmar FIR (VYYY) overflight — generally advisory-clean; verify current NOTAMs. Bay of Bengal and South China Sea transit are fully advisory-clean.",
  explanation_bullets: [
    "Southeast track via Bay of Bengal and Myanmar FIR into South China Sea — airspace_score 0.",
    "Avoids Iranian FIR, Pakistani FIR, and Central Asian FIRs entirely.",
    "Cathay Pacific, Air India, IndiGo all operate DEL–HKG non-stop via this corridor.",
    "Myanmar FIR overflight is advisory-clean; total journey ~5h15m with no advisory zone exposure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: del.id, destination_city_id: hkg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Via Central Asian Corridor",
  carrier_notes: "Occasional northern filings; not the primary industry routing",
  path_geojson: line.([[del.lng, del.lat], [75.0, 38.0], [90.0, 38.0], [105.0, 30.0], [hkg.lng, hkg.lat]]),
  distance_km: 3780, typical_duration_minutes: 335, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Northern DEL–HKG variant routing northwest from Delhi then east across Central Asian FIRs and through China. Airspace_score 1 for Central Asian FIR congestion and Iranian FIR proximity near departure. Bay of Bengal routing is shorter, advisory-cleaner, and the industry standard for DEL–HKG.",
  ranking_context: "Ranked second for DEL–HKG. Airspace_score 1 for Central Asian FIRs and Iranian FIR proximity near DEL. Bay of Bengal routing preferred in all normal conditions.",
  watch_for: "Departure from DEL approaches Iran/Pakistan FIR boundary — verify IRI and OPKR advisory status. Central Asian FIRs (Kazakhstan UAAA, Uzbekistan UTTT) are EASA-monitored.",
  explanation_bullets: [
    "Northern departure from DEL approaches Iranian and Pakistani FIR boundary — airspace_score 1.",
    "Central Asian FIR transit (Kazakhstan, Uzbekistan) is EASA-monitored; requires pre-flight advisory check.",
    "Bay of Bengal routing is shorter, fully advisory-clean (airspace_score 0), and industry-standard.",
    "Northern routing only viable when Bay of Bengal track has exceptional operational constraints."
  ],
  calculated_at: now
})

IO.puts("  ✓ Delhi → Hong Kong (2 corridor families: south_asia_bay/Bay of Bengal, central_asia/northern)")

# ─────────────────────────────────────────────────────────────────────────────
# EUROPE → JAKARTA (reverse of existing Jakarta→Europe routes)
# Three families: via Istanbul · via Dubai · via Singapore/HKG
# Advisory context: Jakarta routes are scored on the European departure leg —
# Iran/Gulf exposure is identical to the equivalent Europe→Singapore routing.
# ─────────────────────────────────────────────────────────────────────────────

for {eu_city, eu_var, eu_lng, eu_lat, dist_ist, dur_ist, dist_dxb, dur_dxb, dist_sin, dur_sin} <- [
  {"London",    lhr, lhr.lng, lhr.lat, 13500, 900, 13100, 930, 13800, 960},
  {"Amsterdam", ams, ams.lng, ams.lat, 13200, 880, 12800, 910, 13500, 940},
  {"Frankfurt", fra, fra.lng, fra.lat, 12900, 870, 12500, 895, 13200, 930},
  {"Paris",     cdg, cdg.lng, cdg.lat, 13300, 895, 12900, 920, 13600, 950}
] do
  # Family 1: Via Istanbul (Turkey hub — advisory-minimised option)
  route = upsert_route.(%{
    origin_city_id: eu_var.id, destination_city_id: cgk.id, via_hub_city_id: sin.id,
    corridor_family: "turkey_hub",
    route_name: "Via Istanbul",
    carrier_notes: "Turkish Airlines (TK) · #{eu_city}–IST–SIN–CGK connection",
    path_geojson: line.([[eu_lng, eu_lat], [ist.lng, ist.lat], [sin.lng, sin.lat], [cgk.lng, cgk.lat]]),
    distance_km: dist_ist, typical_duration_minutes: dur_ist,
    is_active: true, last_reviewed_at: reviewed
  })
  upsert_score.(route, %{
    airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
    recommendation_text: "#{eu_city}–Jakarta via Istanbul and Singapore. The departure leg crosses Central Asian FIRs with EASA advisories — airspace_score 1. Turkish Airlines provides the key #{eu_city}–IST connection; Singapore Airlines or Garuda Indonesia continues IST→SIN→CGK. Best option when avoiding Gulf hub is preferable and transit time at IST is acceptable.",
    ranking_context: "Ranked first for #{eu_city}–Jakarta: shortest total flight time via IST/SIN. Airspace_score 1 for Central Asian FIRs on the European leg. Hub_score 1 for the dual-transit complexity.",
    watch_for: "Central Asian FIRs (Kazakhstan UAAA, Uzbekistan UTTT) — EASA-monitored on the #{eu_city}–IST departure. Monitor Turkish FIR (LTAA) NOTAMs. IST→SIN connection should allow 90min+ minimum transfer.",
    explanation_bullets: [
      "#{eu_city}–IST leg crosses Central Asian airspace approaching Turkish FIR — airspace_score 1.",
      "IST–SIN leg is advisory-clean; SIN–CGK approach is fully clean.",
      "Turkish Airlines operates reliable #{eu_city}–IST frequencies; SQ/GA continue to Jakarta.",
      "Two transit stops (IST, SIN) add complexity but airspace exposure is lower than Gulf routing."
    ],
    calculated_at: now
  })

  # Family 2: Via Dubai (Gulf hub — Iran FIR exposure on European departure)
  route = upsert_route.(%{
    origin_city_id: eu_var.id, destination_city_id: cgk.id, via_hub_city_id: dxb.id,
    corridor_family: "gulf_dubai",
    route_name: "Via Dubai",
    carrier_notes: "Emirates (EK) · #{eu_city}–DXB–CGK daily non-stop from Dubai",
    path_geojson: line.([[eu_lng, eu_lat], [dxb.lng, dxb.lat], [cgk.lng, cgk.lat]]),
    distance_km: dist_dxb, typical_duration_minutes: dur_dxb,
    is_active: true, last_reviewed_at: reviewed
  })
  upsert_score.(route, %{
    airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
    recommendation_text: "#{eu_city}–Jakarta via Dubai. Emirates operates direct DXB–CGK service; the #{eu_city}–DXB leg uses the northern routing past Iran FIR, giving airspace_score 2. DXB–CGK is advisory-clean over the Indian Ocean and Indonesia. Best for passengers who prioritise single-hub simplicity over airspace minimisation — monitor Iranian FIR advisory status.",
    ranking_context: "Ranked second for #{eu_city}–Jakarta via Gulf hub. Airspace_score 2 for Iranian FIR exposure on European departure. Single transit at DXB (hub_score 0) is the simplicity advantage.",
    watch_for: "Iranian FIR (OIIX) — EASA maintains flight restriction advisory on #{eu_city}–DXB northern routing. Monitor for advisory escalation. Southern routing alternative exists via Egypt/Saudi but adds ~40 minutes and may still carry airspace_score 1.",
    explanation_bullets: [
      "#{eu_city}–DXB northern departure approaches Iranian FIR — airspace_score 2; EASA advisory applies.",
      "DXB–CGK flies south over Arabian Sea, India, and into Indonesian FIR — fully advisory-clean.",
      "Emirates DXB–CGK is a high-frequency, reliable connection.",
      "Single hub simplicity at DXB; total journey ~15–16h depending on departure city."
    ],
    calculated_at: now
  })

  # Family 3: Via Singapore (direct routing — southerly departure or HKG)
  route = upsert_route.(%{
    origin_city_id: eu_var.id, destination_city_id: cgk.id, via_hub_city_id: sin.id,
    corridor_family: "gulf_southern",
    route_name: "Via Singapore",
    carrier_notes: "Singapore Airlines (SQ) · #{eu_city}–SIN–CGK; Garuda Indonesia (GA) · #{eu_city}–SIN–CGK",
    path_geojson: line.([[eu_lng, eu_lat], [30.0, 30.0], [55.0, 20.0], [75.0, 12.0], [sin.lng, sin.lat], [cgk.lng, cgk.lat]]),
    distance_km: dist_sin, typical_duration_minutes: dur_sin,
    is_active: true, last_reviewed_at: reviewed
  })
  upsert_score.(route, %{
    airspace_score: 1, corridor_score: 0, hub_score: 0, complexity_score: 1, operational_score: 0,
    recommendation_text: "#{eu_city}–Jakarta via Singapore, using the southern Egypt/Saudi routing. Avoids the Iranian FIR by routing through Egyptian and Saudi Arabian FIRs before crossing the Indian Ocean into SIN. Airspace_score 1 vs score 2 for Gulf northern routing. Singapore Airlines and Garuda Indonesia both offer #{eu_city}–SIN–CGK connections.",
    ranking_context: "Advisory-minimised option for #{eu_city}–Jakarta. Airspace_score 1 vs score 2 for Gulf northern routing. Longer geometry (+~900 km vs via IST) but avoids Iranian FIR. SIN hub is high-quality (hub_score 0).",
    watch_for: "Egyptian FIR (HECC) and Saudi Arabian FIR (OEDF) — generally advisory-clean but monitor NOTAM status. The SIN–CGK final approach is fully advisory-clean.",
    explanation_bullets: [
      "Southern routing via Egypt and Saudi Arabia FIRs avoids Iranian FIR — airspace_score 1 (vs 2 for northern).",
      "Indian Ocean crossing and SIN approach are fully advisory-clean.",
      "Singapore Airlines and Garuda Indonesia offer reliable #{eu_city}–SIN connections.",
      "SIN–CGK is a short 1.5h hop; strong onward connectivity from Changi."
    ],
    calculated_at: now
  })

  IO.puts("  ✓ #{eu_city} → Jakarta (3 corridor families: turkey_hub/IST, gulf_dubai/DXB, gulf_southern/SIN)")
end

# ─────────────────────────────────────────────────────────────────────────────
# JAKARTA INTRA-ASIA: Jakarta ↔ Tokyo · Jakarta ↔ Seoul
# Advisory context: all intra-Asia Jakarta routes use SE Asian / South China Sea
# corridors — fully advisory-clean (airspace_score 0 throughout).
# ─────────────────────────────────────────────────────────────────────────────

# JAKARTA ↔ TOKYO
route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: nrt.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · CGK–SIN–NRT; Garuda Indonesia (GA) · CGK–SIN–NRT",
  path_geojson: line.([[cgk.lng, cgk.lat], [sin.lng, sin.lat], [118.0, 28.0], [nrt.lng, nrt.lat]]),
  distance_km: 6800, typical_duration_minutes: 520, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CGK–NRT via Singapore, routing north over the South China Sea and East China Sea into Japan. Fully advisory-clean — the corridor avoids all current advisory zones including Iranian FIR, Central Asian FIRs, and Russian airspace. Singapore Airlines and Garuda Indonesia provide good CGK–SIN connections; SQ continues SIN–NRT daily. Preferred when hub transit is acceptable and airspace minimisation is the priority.",
  ranking_context: "Top-ranked CGK–NRT routing. Airspace_score 0 — fully advisory-clean. Single hub at SIN (hub_score 0); corridor_score 1 for South China Sea single-path dependency.",
  watch_for: "South China Sea and East China Sea transit are fully advisory-clean. Monitor SIN transit time — SQ CGK–SIN frequencies are high and allow tight connections.",
  explanation_bullets: [
    "CGK–SIN is a 1.5h hop; SIN–NRT continues north over South China Sea and East China Sea.",
    "Fully advisory-clean: avoids Iranian FIR, Central Asian FIRs, and Russian FIR entirely.",
    "Singapore Airlines has the highest CGK–SIN–NRT frequency and reliability.",
    "South China Sea routing is operationally standard and advisory-clean year-round."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: nrt.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · CGK–HKG–NRT; Hong Kong Airlines connections",
  path_geojson: line.([[cgk.lng, cgk.lat], [hkg.lng, hkg.lat], [128.0, 32.0], [nrt.lng, nrt.lat]]),
  distance_km: 6950, typical_duration_minutes: 545, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CGK–NRT via Hong Kong, routing northeast over South China Sea into HKG then east over East China Sea to Japan. Fully advisory-clean corridor. Cathay Pacific provides strong CGK–HKG connections with reliable HKG–NRT service. Preferred when HKG transit times and Cathay Pacific's dense schedule offer a better connection than the SIN routing.",
  ranking_context: "Ranked second for CGK–NRT. Airspace_score 0 — equivalent advisory cleanliness to SIN routing. Slightly longer geometry via HKG; preferred when Cathay Pacific schedules are more convenient.",
  watch_for: "CGK–HKG–NRT is fully advisory-clean. Monitor HKG connection time — Cathay Pacific offers multiple CGK–HKG daily frequencies.",
  explanation_bullets: [
    "CGK–HKG leg routes northeast over South China Sea — fully advisory-clean; airspace_score 0.",
    "HKG–NRT continues east over East China Sea — also fully advisory-clean.",
    "Cathay Pacific operates reliable CGK–HKG connections; continues HKG–NRT daily.",
    "Total geometry ~6,950 km; slightly longer than SIN routing but equivalent advisory score."
  ],
  calculated_at: now
})

IO.puts("  ✓ Jakarta → Tokyo (2 corridor families: southeast_asia/SIN, north_asia_hkg/HKG)")

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: cgk.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · NRT–SIN–CGK; Garuda Indonesia (GA) · NRT–SIN–CGK",
  path_geojson: line.([[nrt.lng, nrt.lat], [128.0, 32.0], [sin.lng, sin.lat], [cgk.lng, cgk.lat]]),
  distance_km: 6800, typical_duration_minutes: 515, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "NRT–CGK via Singapore, routing south over the East China Sea and South China Sea into SIN then a short hop to Jakarta. Fully advisory-clean throughout — avoids all advisory zones. Singapore Airlines operates the anchor NRT–SIN service; Garuda Indonesia and SQ provide SIN–CGK. The SIN hub is well-suited for Japan–Indonesia connections with high frequency.",
  ranking_context: "Top-ranked NRT–CGK routing. Airspace_score 0 — fully advisory-clean. SIN hub quality is high; transit time is manageable.",
  watch_for: "East China Sea and South China Sea transit are fully advisory-clean. SIN–CGK is operationally routine. Monitor SIN connection timing for tight schedule windows.",
  explanation_bullets: [
    "NRT–SIN routes south over East China Sea and South China Sea — airspace_score 0 throughout.",
    "Avoids Russian FIR, Central Asian FIRs, and Iranian FIR entirely on this southeast routing.",
    "Singapore Airlines has the highest NRT–SIN frequency and reliability for onward CGK connections.",
    "SIN–CGK is a 1.5h final hop; Changi provides strong connection infrastructure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: nrt.id, destination_city_id: cgk.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · NRT–HKG–CGK",
  path_geojson: line.([[nrt.lng, nrt.lat], [hkg.lng, hkg.lat], [110.0, 5.0], [cgk.lng, cgk.lat]]),
  distance_km: 6950, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "NRT–CGK via Hong Kong, flying southwest over East China Sea to HKG then south through South China Sea into Indonesia. Fully advisory-clean — avoids all current advisory zones. Cathay Pacific provides reliable NRT–HKG connections with daily HKG–CGK service. Alternative to the SIN routing when Cathay Pacific schedules provide a better connection window.",
  ranking_context: "Ranked second for NRT–CGK. Airspace_score 0 — equivalent to SIN routing. Slightly longer geometry; preferred when Cathay Pacific HKG schedules align better than Singapore Airlines SIN options.",
  watch_for: "NRT–HKG–CGK is fully advisory-clean year-round. Cathay Pacific NRT–HKG is a reliable high-frequency service.",
  explanation_bullets: [
    "NRT–HKG southwest over East China Sea — advisory-clean; airspace_score 0.",
    "HKG–CGK southbound through South China Sea and into Indonesian FIR — also advisory-clean.",
    "Cathay Pacific operates this routing with reliable frequency.",
    "HKG is a strong transit hub for Japan–Indonesia connections."
  ],
  calculated_at: now
})

IO.puts("  ✓ Tokyo → Jakarta (2 corridor families: southeast_asia/SIN, north_asia_hkg/HKG)")

# JAKARTA ↔ SEOUL
route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: icn.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · CGK–SIN–ICN; Korean Air (KE) · CGK–ICN non-stop available",
  path_geojson: line.([[cgk.lng, cgk.lat], [sin.lng, sin.lat], [122.0, 25.0], [icn.lng, icn.lat]]),
  distance_km: 5600, typical_duration_minutes: 440, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CGK–ICN via Singapore, routing north over South China Sea and East China Sea into Korea. Fully advisory-clean throughout. Korean Air also operates direct CGK–ICN non-stop service which avoids the SIN transit entirely. The via-SIN option works well when Korean Air direct flights are sold out or SQ offers better pricing.",
  ranking_context: "Top-ranked for CGK–ICN via hub. Korean Air direct CGK–ICN is preferred when available (no transit). SIN routing is the best hub option otherwise — airspace_score 0, clean corridor.",
  watch_for: "South China Sea and East China Sea transit are fully advisory-clean. Korean Air direct CGK–ICN is also fully advisory-clean on this southeast corridor.",
  explanation_bullets: [
    "CGK–SIN hop then SIN–ICN north over South China Sea — airspace_score 0 throughout.",
    "Korean Air also operates direct CGK–ICN, which avoids SIN transit entirely.",
    "No advisory zone exposure on this corridor — clean routing under all current conditions.",
    "CGK–SIN is a 1.5h hop; SIN–ICN continues with strong SQ connectivity."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cgk.id, destination_city_id: icn.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · CGK–HKG–ICN; Asiana (OZ) via HKG",
  path_geojson: line.([[cgk.lng, cgk.lat], [hkg.lng, hkg.lat], [127.0, 28.0], [icn.lng, icn.lat]]),
  distance_km: 5700, typical_duration_minutes: 455, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CGK–ICN via Hong Kong. Cathay Pacific provides the CGK–HKG leg; multiple carriers connect HKG–ICN. Fully advisory-clean route over South China Sea and into Korea. Alternative when SIN routing is sold out or HKG schedules align better. Korean Air or Asiana connections from HKG are reliable.",
  ranking_context: "Ranked second for CGK–ICN via hub. Airspace_score 0 — equivalent advisory cleanliness to SIN routing. Corridor_score 1 for single-path South China Sea dependency.",
  watch_for: "CGK–HKG–ICN is fully advisory-clean. South China Sea is open and advisory-clean. Monitor HKG connection time.",
  explanation_bullets: [
    "CGK–HKG northeast over South China Sea — advisory-clean; airspace_score 0.",
    "HKG–ICN continues north over East China Sea — also fully advisory-clean.",
    "Cathay Pacific operates CGK–HKG with reliable daily frequencies.",
    "Korean Air and Asiana provide strong HKG–ICN connections."
  ],
  calculated_at: now
})

IO.puts("  ✓ Jakarta → Seoul (2 corridor families: southeast_asia/SIN, north_asia_hkg/HKG)")

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: cgk.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Korean Air (KE) · ICN–CGK non-stop; Singapore Airlines (SQ) · ICN–SIN–CGK",
  path_geojson: line.([[icn.lng, icn.lat], [122.0, 25.0], [sin.lng, sin.lat], [cgk.lng, cgk.lat]]),
  distance_km: 5600, typical_duration_minutes: 435, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 0, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "ICN–CGK via Singapore or direct. Korean Air operates ICN–CGK non-stop direct — the cleanest option with no transit stop. The via-SIN routing via Singapore Airlines is the best hub alternative, routing south over East China Sea and South China Sea. Both are fully advisory-clean with no advisory zone exposure.",
  ranking_context: "Top-ranked ICN–CGK routing. Airspace_score 0 — fully advisory-clean. Korean Air direct is preferred when available; SIN hub is best for connections.",
  watch_for: "ICN–CGK is fully advisory-clean regardless of routing family. South China Sea and East China Sea transit are open and advisory-clean.",
  explanation_bullets: [
    "ICN–SIN–CGK routes south over East China Sea and South China Sea — airspace_score 0.",
    "Korean Air also operates direct ICN–CGK, which avoids the SIN transit entirely.",
    "No advisory zone exposure on this SE Asia corridor under any current conditions.",
    "Strong frequency on both Korean Air direct and Singapore Airlines via SIN."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: icn.id, destination_city_id: cgk.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · ICN–HKG–CGK",
  path_geojson: line.([[icn.lng, icn.lat], [127.0, 28.0], [hkg.lng, hkg.lat], [110.0, 5.0], [cgk.lng, cgk.lat]]),
  distance_km: 5700, typical_duration_minutes: 450, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "ICN–CGK via Hong Kong. Cathay Pacific operates the ICN–HKG–CGK connection. Fully advisory-clean routing south over the East China Sea and South China Sea. Alternative to direct and SIN routing when Cathay Pacific schedules fit better.",
  ranking_context: "Ranked second for ICN–CGK via hub. Airspace_score 0 — advisory-clean. Slightly longer than Korean Air direct; corridor_score 1 for South China Sea single-path.",
  watch_for: "ICN–HKG–CGK is fully advisory-clean. Monitor HKG connection time.",
  explanation_bullets: [
    "ICN–HKG southwest over East China Sea — advisory-clean; airspace_score 0.",
    "HKG–CGK south through South China Sea and Indonesian FIR — also advisory-clean.",
    "Cathay Pacific ICN–HKG is a reliable daily service.",
    "Equivalent advisory cleanliness to SIN routing; schedule determines preference."
  ],
  calculated_at: now
})

IO.puts("  ✓ Seoul → Jakarta (2 corridor families: southeast_asia/SIN, north_asia_hkg/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# SYDNEY ↔ AMSTERDAM, SYDNEY ↔ PARIS, FRANKFURT ↔ SYDNEY
# Three families each: via Singapore · via Dubai · via Hong Kong
# Advisory context: all Sydney–Europe routings pass through advisory-light
# southern corridors. Gulf routing via DXB gives airspace_score 1 (Gulf FIR proximity).
# ─────────────────────────────────────────────────────────────────────────────

# SYDNEY → AMSTERDAM
route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: ams.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · SYD–SIN–AMS; KLM codeshare available",
  path_geojson: line.([[syd.lng, syd.lat], [sin.lng, sin.lat], [75.0, 18.0], [35.0, 38.0], [ams.lng, ams.lat]]),
  distance_km: 16800, typical_duration_minutes: 1150, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "SYD–AMS via Singapore, continuing northwest over Indian Ocean, India, and Turkey into Europe. Singapore Airlines operates a strong SYD–SIN–AMS route with KLM codeshare options. The routing avoids Iranian FIR by tracking north of the Gulf through Turkey/Europe. Airspace_score 0 — the route passes well south and then north of active advisory zones.",
  ranking_context: "Top-ranked SYD–AMS routing. Airspace_score 0 — advisory-clean via SIN. SIN hub is the highest-quality connectivity point for SYD–Europe traffic; KLM partnership enhances AMS options.",
  watch_for: "SYD–SIN and Indian Ocean transit are fully advisory-clean. Turkey FIR (LTAA) on the final European approach is advisory-clean. No current advisory zone exposure on standard SIN routing.",
  explanation_bullets: [
    "SYD–SIN routes northwest via Darwin/Indonesia — clean corridor; airspace_score 0.",
    "Indian Ocean transit and approach into Turkey/Europe avoids Iranian FIR.",
    "Singapore Airlines SYD–SIN–AMS with KLM partnership is the primary option.",
    "Total ~28h including transit; longest daily-operated route family."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: ams.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · SYD–DXB–AMS daily",
  path_geojson: line.([[syd.lng, syd.lat], [115.0, -28.0], [85.0, 14.0], [dxb.lng, dxb.lat], [35.0, 40.0], [ams.lng, ams.lat]]),
  distance_km: 17200, typical_duration_minutes: 1200, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "SYD–AMS via Dubai. Emirates operates SYD–DXB–AMS daily. The SYD–DXB leg approaches Gulf FIR airspace, giving airspace_score 1 — Gulf region monitoring is recommended. DXB–AMS continues northwest over Turkey and Central Europe, which is advisory-clean. Emirates provides the highest-frequency SYD–AMS capacity via this hub.",
  ranking_context: "Ranked second for SYD–AMS. Airspace_score 1 for Gulf FIR on SYD–DXB approach. High-frequency Emirates operation is the convenience advantage. SIN routing preferred when airspace minimisation is priority.",
  watch_for: "Gulf FIR (OMAE/OEJD) on the DXB approach — monitor Gulf regional advisory status. DXB–AMS via Turkey is advisory-clean. Emirates SYD–DXB is a daily long-haul operation.",
  explanation_bullets: [
    "SYD–DXB approaches Gulf FIR from the south — airspace_score 1; monitor Gulf advisories.",
    "DXB–AMS via Turkey and Central Europe is advisory-clean.",
    "Emirates SYD–DXB–AMS is the highest-frequency European option from Sydney.",
    "DXB hub has strong transfer infrastructure for Sydney–Amsterdam traffic."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: ams.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · SYD–HKG–AMS; KLM codeshare via HKG",
  path_geojson: line.([[syd.lng, syd.lat], [hkg.lng, hkg.lat], [80.0, 42.0], [45.0, 46.0], [ams.lng, ams.lat]]),
  distance_km: 17500, typical_duration_minutes: 1230, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "SYD–AMS via Hong Kong, continuing northwest across Central Asia toward Amsterdam. The HKG–AMS leg tracks through Central Asian FIRs (Kazakhstan, Uzbekistan) which carry EASA advisories — airspace_score 1. Cathay Pacific operates SYD–HKG; KLM connections complete to Amsterdam. The SIN routing is preferred for advisory minimisation; HKG is useful when Cathay schedules provide better connection times.",
  ranking_context: "Ranked third for SYD–AMS. Airspace_score 1 for Central Asian FIRs on HKG–AMS leg. Corridor_score 2 for single-path Central Asian dependency. SIN routing preferred for airspace cleanliness.",
  watch_for: "Central Asian FIRs (Kazakhstan UAAA, Uzbekistan UTTT) on the HKG–AMS westbound leg — EASA-monitored. SYD–HKG is advisory-clean.",
  explanation_bullets: [
    "SYD–HKG northeast via South Pacific and South China Sea — advisory-clean.",
    "HKG–AMS westbound crosses Central Asian FIRs — airspace_score 1; EASA advisories apply.",
    "Cathay Pacific SYD–HKG provides reliable daily service; KLM connects to Amsterdam.",
    "Central Asian FIR exposure is the key advisory variable on this routing."
  ],
  calculated_at: now
})

IO.puts("  ✓ Sydney → Amsterdam (3 corridor families: southeast_asia/SIN, gulf_dubai/DXB, north_asia_hkg/HKG)")

# AMSTERDAM → SYDNEY
route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: syd.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · AMS–SIN–SYD; KLM codeshare",
  path_geojson: line.([[ams.lng, ams.lat], [35.0, 38.0], [75.0, 18.0], [sin.lng, sin.lat], [syd.lng, syd.lat]]),
  distance_km: 16800, typical_duration_minutes: 1140, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "AMS–SYD via Singapore. Singapore Airlines and KLM operate joint service on this route. The Amsterdam departure heads southeast through Turkey, India, and into Singapore before continuing to Sydney. Airspace_score 0 — the routing tracks well south of Iranian FIR via Turkey and India. SIN is the strongest hub for AMS–SYD connectivity.",
  ranking_context: "Top-ranked AMS–SYD routing. Airspace_score 0 — advisory-clean via SIN. KLM/SQ partnership provides the most convenient connectivity from Amsterdam.",
  watch_for: "AMS–SIN via Turkey and Indian subcontinent is advisory-clean. SIN–SYD continues southeast over the Indonesian archipelago — fully advisory-clean.",
  explanation_bullets: [
    "AMS departs southeast via Turkey FIR (LTAA) and India — avoids Iranian FIR; airspace_score 0.",
    "Indian subcontinent and SIN approach are advisory-clean.",
    "KLM and Singapore Airlines partnership provides strong AMS–SIN–SYD connectivity.",
    "SIN–SYD continues southeast over Indonesia — advisory-clean approach into Sydney."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: syd.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · AMS–DXB–SYD daily",
  path_geojson: line.([[ams.lng, ams.lat], [35.0, 38.0], [dxb.lng, dxb.lat], [85.0, 14.0], [115.0, -28.0], [syd.lng, syd.lat]]),
  distance_km: 17200, typical_duration_minutes: 1190, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "AMS–SYD via Dubai. Emirates operates this route daily. The AMS–DXB departure can use the northern routing past Iran FIR (airspace_score 2) or southern routing via Egypt/Saudi (airspace_score 1). Emirates' scheduled filing uses the northern track giving the Iranian FIR proximity flag. DXB–SYD southbound is fully advisory-clean over the Indian Ocean.",
  ranking_context: "Ranked second for AMS–SYD. Airspace_score 2 for Iranian FIR on AMS–DXB northern routing. Emirates high frequency is the advantage; SIN routing preferred for advisory minimisation.",
  watch_for: "AMS–DXB northern departure approaches Iranian FIR — EASA advisory applies. Monitor Iranian FIR status. DXB–SYD southbound is advisory-clean.",
  explanation_bullets: [
    "AMS–DXB northern routing approaches Iranian FIR — airspace_score 2; EASA advisory.",
    "DXB–SYD flies south over Arabian Sea, India, and Australian ocean — advisory-clean.",
    "Emirates AMS–DXB–SYD is the highest-frequency European–Australia route via Gulf.",
    "Southern AMS–DXB routing (Egypt/Saudi) exists but reduces advisory exposure only marginally."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: ams.id, destination_city_id: syd.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · AMS–HKG–SYD; KLM codeshare via HKG",
  path_geojson: line.([[ams.lng, ams.lat], [45.0, 46.0], [80.0, 42.0], [hkg.lng, hkg.lat], [syd.lng, syd.lat]]),
  distance_km: 17500, typical_duration_minutes: 1220, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "AMS–SYD via Hong Kong. The Amsterdam departure heads northeast over Central Asian FIRs to HKG (airspace_score 1), then Cathay Pacific continues SYD. Central Asian FIR monitoring required on the AMS–HKG leg. HKG–SYD is advisory-clean over the South China Sea and Pacific approaches.",
  ranking_context: "Ranked third for AMS–SYD. Airspace_score 1 for Central Asian FIRs on AMS–HKG. SIN routing is preferred for advisory cleanliness; HKG useful for schedule fit.",
  watch_for: "Central Asian FIRs (Kazakhstan UAAA, Uzbekistan UTTT) on AMS–HKG leg — EASA-monitored. HKG–SYD is advisory-clean.",
  explanation_bullets: [
    "AMS–HKG eastbound via Central Asian FIRs — airspace_score 1; EASA advisories apply.",
    "HKG–SYD southward via South China Sea — fully advisory-clean.",
    "Cathay Pacific AMS–HKG–SYD is a reliable option when SIN connection is less convenient.",
    "Central Asian FIR is the main advisory variable on this routing."
  ],
  calculated_at: now
})

IO.puts("  ✓ Amsterdam → Sydney (3 corridor families: southeast_asia/SIN, gulf_dubai/DXB, north_asia_hkg/HKG)")

# SYDNEY → PARIS
route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: cdg.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · SYD–SIN–CDG; Air France codeshare",
  path_geojson: line.([[syd.lng, syd.lat], [sin.lng, sin.lat], [75.0, 18.0], [30.0, 38.0], [cdg.lng, cdg.lat]]),
  distance_km: 17000, typical_duration_minutes: 1165, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "SYD–CDG via Singapore. Singapore Airlines and Air France partner on this routing. Departs northwest from Sydney, transits SIN, continues through India and Turkey into Paris. Airspace_score 0 — the SIN routing avoids Iranian FIR by tracking through Turkey FIR rather than over Iran. SIN is the most connectivity-rich hub for SYD–Europe.",
  ranking_context: "Top-ranked SYD–CDG. Airspace_score 0 — advisory-clean via SIN. Air France/SQ partnership provides strong connectivity.",
  watch_for: "SYD–SIN and Indian Ocean transit are advisory-clean. Turkey FIR (LTAA) on European approach is advisory-clean. No current advisory concerns on standard SIN routing.",
  explanation_bullets: [
    "SYD–SIN northwest via Darwin/Indonesia — advisory-clean; airspace_score 0.",
    "SIN–CDG via Indian subcontinent and Turkey avoids Iranian FIR.",
    "Singapore Airlines SYD–SIN–CDG with Air France partnership.",
    "Total ~28h; the SIN hub is the most convenient transit for SYD–Paris traffic."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: syd.id, destination_city_id: cdg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · SYD–DXB–CDG daily",
  path_geojson: line.([[syd.lng, syd.lat], [115.0, -28.0], [85.0, 14.0], [dxb.lng, dxb.lat], [30.0, 40.0], [cdg.lng, cdg.lat]]),
  distance_km: 17400, typical_duration_minutes: 1215, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "SYD–CDG via Dubai. Emirates operates SYD–DXB–CDG daily. The SYD–DXB southbound approach transits Gulf FIR from the southeast — airspace_score 1 for Gulf proximity. DXB–CDG via Turkey is advisory-clean. Emirates provides the highest capacity on SYD–Paris via this hub.",
  ranking_context: "Ranked second for SYD–CDG. Airspace_score 1 for Gulf FIR on SYD–DXB. Emirates provides highest frequency; SIN routing preferred for advisory minimisation.",
  watch_for: "Gulf FIR (OMAE/OEJD) on SYD–DXB approach — monitor Gulf advisory status. DXB–CDG is advisory-clean via Turkey FIR.",
  explanation_bullets: [
    "SYD–DXB approaches Gulf FIR from the south — airspace_score 1; monitor Gulf advisories.",
    "DXB–CDG via Turkey and Central Europe is advisory-clean.",
    "Emirates SYD–DXB–CDG is a daily direct connection with high frequency.",
    "Gulf hub is a convenience advantage; SIN routing preferred when advisory status is elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Sydney → Paris (2 corridor families: southeast_asia/SIN, gulf_dubai/DXB)")

# PARIS → SYDNEY
route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: syd.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · CDG–SIN–SYD; Air France codeshare",
  path_geojson: line.([[cdg.lng, cdg.lat], [30.0, 38.0], [75.0, 18.0], [sin.lng, sin.lat], [syd.lng, syd.lat]]),
  distance_km: 17000, typical_duration_minutes: 1155, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CDG–SYD via Singapore. The Paris departure tracks southeast over Turkey and India into Singapore, then continues to Sydney. Airspace_score 0 — routing uses Turkish FIR approach rather than overflying Iran. Singapore Airlines and Air France jointly operate this routing. The SIN hub is the best connectivity point for CDG–SYD and offers the cleanest advisory profile.",
  ranking_context: "Top-ranked CDG–SYD. Airspace_score 0 — advisory-clean via SIN. Air France/SQ partnership is the primary operated option.",
  watch_for: "CDG–SIN via Turkey FIR (LTAA) and Indian subcontinent is advisory-clean. SIN–SYD via Indonesia is fully advisory-clean.",
  explanation_bullets: [
    "CDG southeast over Turkey and India — avoids Iranian FIR; airspace_score 0.",
    "Indian Ocean and SIN approach are advisory-clean.",
    "Air France/Singapore Airlines partnership operates CDG–SIN–SYD.",
    "SIN–SYD continues southeast over Indonesia — advisory-clean approach into Sydney."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: cdg.id, destination_city_id: syd.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · CDG–DXB–SYD daily",
  path_geojson: line.([[cdg.lng, cdg.lat], [30.0, 40.0], [dxb.lng, dxb.lat], [85.0, 14.0], [115.0, -28.0], [syd.lng, syd.lat]]),
  distance_km: 17400, typical_duration_minutes: 1200, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "CDG–SYD via Dubai. Emirates operates this route daily. The CDG–DXB departure uses the northern routing past Iran FIR — airspace_score 2 for Iranian FIR exposure. DXB–SYD southbound is fully advisory-clean over the Indian Ocean. Emirates provides the highest frequency on CDG–Australia via Gulf, but the SIN routing is preferred when advisory minimisation is the priority.",
  ranking_context: "Ranked second for CDG–SYD. Airspace_score 2 for Iranian FIR on CDG–DXB. Emirates high frequency is the advantage. SIN routing strongly preferred for advisory cleanliness.",
  watch_for: "CDG–DXB northern routing approaches Iranian FIR — EASA advisory applies; verify before departure. DXB–SYD southbound is advisory-clean.",
  explanation_bullets: [
    "CDG–DXB northern routing approaches Iranian FIR — airspace_score 2; EASA advisory.",
    "DXB–SYD southbound over Arabian Sea and Indian Ocean — fully advisory-clean.",
    "Emirates CDG–DXB–SYD has highest frequency from Paris to Australia.",
    "SIN routing is recommended when Iranian FIR advisory is elevated."
  ],
  calculated_at: now
})

IO.puts("  ✓ Paris → Sydney (2 corridor families: southeast_asia/SIN, gulf_dubai/DXB)")

# FRANKFURT → SYDNEY (completing the pair)
route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: syd.id, via_hub_city_id: sin.id,
  corridor_family: "southeast_asia",
  route_name: "Via Singapore",
  carrier_notes: "Singapore Airlines (SQ) · FRA–SIN–SYD; Lufthansa codeshare",
  path_geojson: line.([[fra.lng, fra.lat], [35.0, 38.0], [75.0, 18.0], [sin.lng, sin.lat], [syd.lng, syd.lat]]),
  distance_km: 16700, typical_duration_minutes: 1140, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "FRA–SYD via Singapore. Singapore Airlines and Lufthansa partner on this routing. Frankfurt departs southeast over Turkey, India, and into Singapore before continuing to Sydney. Airspace_score 0 — routing avoids Iranian FIR via Turkey FIR. SIN is the connectivity anchor for FRA–SYD traffic with strong onward SYD service.",
  ranking_context: "Top-ranked FRA–SYD. Airspace_score 0 — advisory-clean via SIN. Lufthansa/SQ partnership provides strong FRA connectivity.",
  watch_for: "FRA–SIN via Turkey and Indian subcontinent is advisory-clean. SIN–SYD over Indonesia is also advisory-clean.",
  explanation_bullets: [
    "FRA southeast via Turkey FIR and India — avoids Iranian FIR; airspace_score 0.",
    "Indian Ocean transit and SIN approach are advisory-clean.",
    "Lufthansa and Singapore Airlines jointly serve FRA–SIN–SYD.",
    "SIN–SYD continues southeast over Indonesia — advisory-clean approach into Sydney."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: syd.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · FRA–DXB–SYD daily; Lufthansa connections",
  path_geojson: line.([[fra.lng, fra.lat], [35.0, 38.0], [dxb.lng, dxb.lat], [85.0, 14.0], [115.0, -28.0], [syd.lng, syd.lat]]),
  distance_km: 17100, typical_duration_minutes: 1190, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "FRA–SYD via Dubai. Emirates operates FRA–DXB–SYD daily. The FRA–DXB departure uses northern routing past Iran FIR — airspace_score 2 for Iranian FIR proximity. DXB–SYD southbound is fully advisory-clean. Emirates provides the highest capacity on FRA–Australia via Gulf. SIN routing strongly preferred when advisory minimisation matters.",
  ranking_context: "Ranked second for FRA–SYD. Airspace_score 2 for Iranian FIR on FRA–DXB. Emirates frequency advantage. SIN routing preferred for airspace cleanliness.",
  watch_for: "FRA–DXB northern routing approaches Iranian FIR — EASA advisory; verify status before departure. DXB–SYD is advisory-clean.",
  explanation_bullets: [
    "FRA–DXB northern routing approaches Iranian FIR — airspace_score 2; EASA advisory.",
    "DXB–SYD southbound over Arabian Sea and Indian Ocean — advisory-clean.",
    "Emirates FRA–DXB–SYD is the highest-frequency Frankfurt–Australia service via Gulf.",
    "SIN routing is recommended when Iranian FIR advisory status is elevated."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: syd.id, via_hub_city_id: hkg.id,
  corridor_family: "north_asia_hkg",
  route_name: "Via Hong Kong",
  carrier_notes: "Cathay Pacific (CX) · FRA–HKG–SYD; Lufthansa codeshare via HKG",
  path_geojson: line.([[fra.lng, fra.lat], [45.0, 46.0], [80.0, 42.0], [hkg.lng, hkg.lat], [syd.lng, syd.lat]]),
  distance_km: 17400, typical_duration_minutes: 1220, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "FRA–SYD via Hong Kong. The Frankfurt departure tracks northeast over Central Asian FIRs (Kazakhstan, Uzbekistan) to HKG — airspace_score 1 for EASA-monitored Central Asian airspace. Cathay Pacific operates FRA–HKG–SYD. HKG–SYD is advisory-clean. Third choice behind SIN (cleanest) and DXB (highest frequency).",
  ranking_context: "Ranked third for FRA–SYD. Airspace_score 1 for Central Asian FIRs on FRA–HKG. Corridor_score 2 for single-path Central Asian dependency.",
  watch_for: "Central Asian FIRs (Kazakhstan UAAA, Uzbekistan UTTT) on FRA–HKG leg — EASA-monitored. HKG–SYD is advisory-clean.",
  explanation_bullets: [
    "FRA–HKG eastbound via Central Asian FIRs — airspace_score 1; EASA advisories apply.",
    "HKG–SYD southward via South China Sea and Pacific — advisory-clean.",
    "Cathay Pacific FRA–HKG–SYD with Lufthansa partnership.",
    "SIN routing preferred for advisory cleanliness; HKG useful for schedule fit."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Sydney (3 corridor families: southeast_asia/SIN, gulf_dubai/DXB, north_asia_hkg/HKG)")

# ─────────────────────────────────────────────────────────────────────────────
# PATCH: watch_for for clean India → SE Asia corridors
# These routes were seeded with watch_for: nil — add advisory context note.
# ─────────────────────────────────────────────────────────────────────────────

clean_watch = "No airspace advisory concerns on this corridor under current conditions."

for {orig_id, dest_id, name} <- [
  {del.id, sin.id, "Direct"},
  {del.id, sin.id, "Via Bangkok"},
  {del.id, sin.id, "Via Kuala Lumpur"},
  {del.id, bkk.id, "Direct"},
  {del.id, bkk.id, "Via Singapore"},
  {del.id, bkk.id, "Via Kuala Lumpur"},
  {bom.id, sin.id, "Direct"},
  {bom.id, sin.id, "Via Bangkok"},
  {bom.id, sin.id, "Via Kuala Lumpur"},
  {bom.id, bkk.id, "Direct"},
  {bom.id, bkk.id, "Via Singapore"},
  {bom.id, bkk.id, "Via Kuala Lumpur"}
] do
  case Repo.get_by(Route, origin_city_id: orig_id, destination_city_id: dest_id, route_name: name) do
    nil -> :ok
    route ->
      Repo.update_all(
        from(s in RouteScore, where: s.route_id == ^route.id and is_nil(s.watch_for)),
        set: [watch_for: clean_watch]
      )
  end
end
IO.puts("  ✓ Fixed watch_for for 12 clean India→SE Asia routes")

# ─────────────────────────────────────────────────────────────────────────────
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
# MUNICH → BANGKOK
# Three families: Turkey hub (IST) · Gulf (DXB) · Gulf (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: muc.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) · daily MUC–IST–BKK",
  path_geojson: line.([[muc.lng, muc.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9450, typical_duration_minutes: 700, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest option for MUC→BKK. Avoids the Middle East advisory zone. Lufthansa–Turkish connection via IST is well-timed and reliable.",
  ranking_context: "Top option for MUC→BKK: avoids advisory zone on both legs. IST is geographically efficient from Munich and Turkish Airlines has strong BKK frequency.",
  watch_for: "Monitor Turkish Airlines IST operations if regional turbulence affects Turkey. TK has 4+ daily IST–BKK departures.",
  explanation_bullets: [
    "MUC–IST uses standard central European routing — no advisory exposure.",
    "IST–BKK routes east with peripheral near-zone exposure only.",
    "Lufthansa + Turkish Airlines connection at IST is well-coordinated with strong rebooking depth.",
    "Journey approximately 11.5 hours — among the more time-efficient options for this pair."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: muc.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) · daily MUC–DXB–BKK",
  path_geojson: line.([[muc.lng, muc.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9700, typical_duration_minutes: 740, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "High frequency via Emirates, but the MUC–DXB leg crosses the active Middle East advisory zone. Use when Istanbul is unavailable or sold out.",
  ranking_context: "Ranked below Istanbul: MUC–DXB crosses the advisory zone. Emirates provides strong rebooking depth if the first leg is disrupted.",
  watch_for: "Monitor Middle East advisory zone escalation. Emirates has 5+ daily MUC–DXB departures — strong rebooking options if needed.",
  explanation_bullets: [
    "MUC–DXB transits the active Middle East advisory zone — real exposure on the first segment.",
    "Emirates' high MUC frequency gives solid rebooking options if disrupted.",
    "DXB–BKK is a clean, well-operated segment with no active advisory concerns.",
    "Journey roughly 45–60 minutes longer than Istanbul option."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: muc.id, destination_city_id: bkk.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · MUC–DOH–BKK daily",
  path_geojson: line.([[muc.lng, muc.lat], [doh.lng, doh.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9650, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Same advisory zone exposure as Dubai option; slightly more direct geometry. Choose based on QR preference or schedule fit.",
  ranking_context: "Equal to the Dubai option on all factors. Doha sits slightly more directly between Munich and Bangkok. Choose based on airline preference.",
  watch_for: "MUC–DOH crosses the same advisory zone as MUC–DXB. Monitor QR operational alerts if regional tensions rise.",
  explanation_bullets: [
    "Qatar Airways operates MUC–DOH–BKK with good daily frequency.",
    "MUC–DOH crosses the Middle East advisory zone — same exposure as Dubai option.",
    "DOH hub is world-class with strong Southeast Asia connectivity.",
    "Slightly shorter total distance than Dubai routing due to Doha's more easterly position."
  ],
  calculated_at: now
})

IO.puts("  ✓ Munich → Bangkok (3 corridor families: IST, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# MUNICH → SINGAPORE
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: muc.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Lufthansa (LH) + Turkish Airlines (TK) · MUC–IST–SIN",
  path_geojson: line.([[muc.lng, muc.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 10300, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest corridor for MUC→SIN. Istanbul hub avoids the Middle East advisory zone. Strong Lufthansa–Turkish connection with good SIN frequency.",
  ranking_context: "Top option for MUC→SIN: avoids the advisory zone. IST–SIN is one of Turkish Airlines' highest-frequency long-haul routes.",
  watch_for: "Check Turkish Airlines IST operations if regional conditions affect Turkey. IST–SIN has 7+ weekly departures — good rebooking depth.",
  explanation_bullets: [
    "MUC–IST is fully advisory-clean — standard European routing.",
    "IST–SIN routes south of the advisory zone with only peripheral near-zone exposure.",
    "Turkish Airlines operates strong daily IST–SIN service.",
    "Total journey approximately 12.5–13 hours."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: muc.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Lufthansa (LH) + Emirates (EK) · MUC–DXB–SIN",
  path_geojson: line.([[muc.lng, muc.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
  distance_km: 10600, typical_duration_minutes: 790, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai offers high frequency to Singapore, but the MUC–DXB leg crosses the advisory zone. Use when Istanbul options are limited.",
  ranking_context: "Ranked below Istanbul: advisory zone exposure on MUC–DXB first leg. Emirates provides strong DXB–SIN frequency with excellent hub connectivity.",
  watch_for: "Monitor Middle East advisory zone. Emirates operates 5+ daily MUC–DXB departures — strong rebooking depth if disrupted.",
  explanation_bullets: [
    "MUC–DXB crosses the active Middle East advisory zone.",
    "DXB–SIN is a clean, high-frequency segment — no advisory concerns.",
    "Emirates hub at DXB is among the world's best for Singapore connectivity.",
    "Journey roughly 30–45 minutes longer than Istanbul option."
  ],
  calculated_at: now
})

IO.puts("  ✓ Munich → Singapore (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → MUNICH  (reverse)
# Three families: Turkey hub (IST) · Gulf (DXB) · Gulf (DOH)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: muc.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Lufthansa (LH) · BKK–IST–MUC daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [muc.lng, muc.lat]]),
  distance_km: 9450, typical_duration_minutes: 700, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest BKK→MUC option. Turkish Airlines via IST avoids the Middle East advisory zone. IST is well-positioned between Bangkok and Munich.",
  ranking_context: "Top option for BKK→MUC: avoids advisory zone on both legs. Turkish Airlines has strong BKK–IST frequency.",
  watch_for: "Monitor Turkish Airlines IST operations if regional conditions affect Turkey. Good rebooking depth at IST.",
  explanation_bullets: [
    "BKK–IST routes northwest — near-zone peripheral exposure only.",
    "IST–MUC is fully advisory-clean standard European routing.",
    "Turkish Airlines + Lufthansa connection at IST is well-timed."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: muc.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) + Lufthansa (LH) · BKK–DXB–MUC daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [muc.lng, muc.lat]]),
  distance_km: 9700, typical_duration_minutes: 740, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai to Munich. DXB–MUC leg crosses the advisory zone. Use when Istanbul options are unavailable.",
  ranking_context: "Ranked below Istanbul: DXB–MUC crosses the advisory zone on the European arrival leg.",
  watch_for: "DXB–MUC crosses the Middle East advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "BKK–DXB is a clean, well-operated segment.",
    "DXB–MUC transits the active Middle East advisory zone on the European arrival leg.",
    "Emirates provides strong DXB hub rebooking options if needed."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: muc.id, via_hub_city_id: doh.id,
  corridor_family: "gulf_doha",
  route_name: "Via Doha",
  carrier_notes: "Qatar Airways (QR) · BKK–DOH–MUC daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [doh.lng, doh.lat], [muc.lng, muc.lat]]),
  distance_km: 9650, typical_duration_minutes: 730, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Qatar Airways via Doha. Same advisory zone exposure as Dubai option. Choose based on QR preference or schedule fit.",
  ranking_context: "Equal to Dubai option on all factors. Choose based on airline preference.",
  watch_for: "DOH–MUC crosses the same advisory zone as DXB–MUC. Monitor QR advisories if regional tensions rise.",
  explanation_bullets: [
    "BKK–DOH departure is advisory-clean.",
    "DOH–MUC European arrival leg crosses the advisory zone.",
    "Qatar Airways operates reliable BKK–DOH–MUC service."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Munich (3 corridor families: IST, DXB, DOH)")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → MUNICH  (reverse)
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: muc.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Lufthansa (LH) · SIN–IST–MUC",
  path_geojson: line.([[sin.lng, sin.lat], [ist.lng, ist.lat], [muc.lng, muc.lat]]),
  distance_km: 10300, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest SIN→MUC corridor. Turkish Airlines via IST avoids Gulf advisory zone. IST is well-positioned and connects efficiently to Munich.",
  ranking_context: "Top option for SIN→MUC: avoids the advisory zone. Turkish Airlines has strong SIN–IST frequency.",
  watch_for: "Monitor Turkish Airlines IST operations. SIN–IST has good weekly frequency with strong rebooking depth.",
  explanation_bullets: [
    "SIN–IST routes northwest with near-zone peripheral exposure only.",
    "IST–MUC is advisory-clean standard European routing.",
    "Turkish Airlines + Lufthansa connection is well-coordinated."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: muc.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) + Lufthansa (LH) · SIN–DXB–MUC",
  path_geojson: line.([[sin.lng, sin.lat], [dxb.lng, dxb.lat], [muc.lng, muc.lat]]),
  distance_km: 10600, typical_duration_minutes: 790, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. DXB–MUC crosses the advisory zone on the European arrival leg. Use when Istanbul options are limited.",
  ranking_context: "Ranked below Istanbul: DXB–MUC advisory zone exposure. Emirates provides strong SIN–DXB frequency and excellent hub connectivity.",
  watch_for: "DXB–MUC European arrival leg crosses the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "SIN–DXB departure is a clean, high-frequency segment.",
    "DXB–MUC crosses the active Middle East advisory zone on arrival leg.",
    "Emirates hub at DXB is world-class for European connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Munich (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# ROME → BANGKOK
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fco.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · FCO–IST–BKK daily",
  path_geojson: line.([[fco.lng, fco.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 8500, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest FCO→BKK corridor. Turkish Airlines via Istanbul avoids the Gulf advisory zone. IST is well-positioned for Southeast Asia connections.",
  ranking_context: "Top option for FCO→BKK: avoids the advisory zone. Turkish Airlines has reliable FCO–IST–BKK coverage.",
  watch_for: "Monitor Turkish Airlines IST operations. FCO–IST–BKK has good frequency and rebooking depth.",
  explanation_bullets: [
    "FCO–IST is clean short European leg.",
    "IST–BKK routes east with near-zone peripheral exposure only.",
    "Turkish Airlines operates efficient FCO–IST–BKK itineraries."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fco.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · FCO–DXB–BKK daily",
  path_geojson: line.([[fco.lng, fco.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 9100, typical_duration_minutes: 710, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. FCO–DXB crosses the active advisory zone. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: FCO–DXB advisory zone crossing. Emirates provides strong DXB–BKK frequency.",
  watch_for: "FCO–DXB transits the Middle East advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "FCO–DXB crosses the active Middle East advisory zone.",
    "DXB–BKK departure is clean and high-frequency.",
    "Emirates hub at DXB is world-class for Southeast Asia connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Rome → Bangkok (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# ROME → SINGAPORE
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fco.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Singapore Airlines (SQ) · FCO–IST–SIN",
  path_geojson: line.([[fco.lng, fco.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 10200, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest FCO→SIN corridor. Turkish Airlines via Istanbul avoids Gulf advisory zone exposure. IST–SIN is a well-operated long-haul segment.",
  ranking_context: "Top option for FCO→SIN: avoids the advisory zone. TK has reliable FCO–IST coverage.",
  watch_for: "Monitor Turkish Airlines IST operations. IST–SIN has good weekly frequency.",
  explanation_bullets: [
    "FCO–IST is a clean short European leg.",
    "IST–SIN routes east with near-zone peripheral exposure only.",
    "Turkish Airlines provides efficient FCO–IST–SIN itineraries."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fco.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) + Singapore Airlines (SQ) · FCO–DXB–SIN daily",
  path_geojson: line.([[fco.lng, fco.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
  distance_km: 10800, typical_duration_minutes: 820, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. FCO–DXB crosses the advisory zone. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: FCO–DXB advisory zone crossing. Emirates provides excellent DXB–SIN frequency.",
  watch_for: "FCO–DXB transits the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "FCO–DXB crosses the active Middle East advisory zone.",
    "DXB–SIN departure is clean and very high-frequency.",
    "Emirates hub provides excellent SIN connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Rome → Singapore (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → ROME  (reverse)
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: fco.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · BKK–IST–FCO daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [fco.lng, fco.lat]]),
  distance_km: 8500, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest BKK→FCO corridor. Turkish Airlines via Istanbul avoids Gulf advisory zone. IST is well-positioned for European arrivals.",
  ranking_context: "Top option for BKK→FCO: avoids the advisory zone. TK has strong BKK–IST–FCO frequency.",
  watch_for: "Monitor Turkish Airlines IST operations. BKK–IST–FCO has good frequency and rebooking depth.",
  explanation_bullets: [
    "BKK–IST routes northwest with near-zone peripheral exposure only.",
    "IST–FCO is clean standard European routing.",
    "Turkish Airlines provides efficient BKK–IST–FCO connections."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: fco.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · BKK–DXB–FCO daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [fco.lng, fco.lat]]),
  distance_km: 9100, typical_duration_minutes: 710, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. DXB–FCO crosses the active advisory zone on the European arrival leg. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: DXB–FCO advisory zone crossing. Emirates provides strong BKK–DXB frequency.",
  watch_for: "DXB–FCO European arrival leg crosses the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "BKK–DXB departure is clean and high-frequency.",
    "DXB–FCO crosses the active Middle East advisory zone.",
    "Emirates hub at DXB provides strong rebooking options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Rome (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → ROME  (reverse)
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: fco.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Singapore Airlines (SQ) · SIN–IST–FCO",
  path_geojson: line.([[sin.lng, sin.lat], [ist.lng, ist.lat], [fco.lng, fco.lat]]),
  distance_km: 10200, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest SIN→FCO corridor. Turkish Airlines via Istanbul avoids the Gulf advisory zone. IST–FCO is a clean standard European arrival.",
  ranking_context: "Top option for SIN→FCO: avoids the advisory zone. TK has strong SIN–IST frequency.",
  watch_for: "Monitor Turkish Airlines IST operations. SIN–IST–FCO has good frequency.",
  explanation_bullets: [
    "SIN–IST routes northwest with near-zone peripheral exposure only.",
    "IST–FCO is clean standard European routing.",
    "Turkish Airlines and SQ both operate SIN–IST legs reliably."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: fco.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) + Singapore Airlines (SQ) · SIN–DXB–FCO daily",
  path_geojson: line.([[sin.lng, sin.lat], [dxb.lng, dxb.lat], [fco.lng, fco.lat]]),
  distance_km: 10800, typical_duration_minutes: 820, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. DXB–FCO crosses the advisory zone on the European arrival leg. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: DXB–FCO advisory zone crossing. Emirates provides excellent SIN–DXB frequency.",
  watch_for: "DXB–FCO European arrival leg crosses the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "SIN–DXB departure is clean and very high-frequency.",
    "DXB–FCO crosses the active Middle East advisory zone.",
    "Emirates hub at DXB is world-class for European connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Rome (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# ZURICH → BANGKOK
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: zrh.id, destination_city_id: bkk.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · ZRH–IST–BKK daily",
  path_geojson: line.([[zrh.lng, zrh.lat], [ist.lng, ist.lat], [bkk.lng, bkk.lat]]),
  distance_km: 8300, typical_duration_minutes: 645, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest ZRH→BKK corridor. Turkish Airlines via Istanbul avoids the Gulf advisory zone. Short ZRH–IST hop connects efficiently to BKK.",
  ranking_context: "Top option for ZRH→BKK: avoids the advisory zone. TK has daily ZRH–IST–BKK coverage.",
  watch_for: "Monitor Turkish Airlines IST operations. ZRH–IST is a short clean connection.",
  explanation_bullets: [
    "ZRH–IST is a short clean European hop.",
    "IST–BKK routes east with near-zone peripheral exposure only.",
    "Turkish Airlines provides efficient ZRH–IST–BKK itineraries."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: zrh.id, destination_city_id: bkk.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · ZRH–DXB–BKK daily",
  path_geojson: line.([[zrh.lng, zrh.lat], [dxb.lng, dxb.lat], [bkk.lng, bkk.lat]]),
  distance_km: 8900, typical_duration_minutes: 695, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. ZRH–DXB crosses the active advisory zone. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: ZRH–DXB advisory zone crossing. Emirates provides strong DXB–BKK frequency.",
  watch_for: "ZRH–DXB transits the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "ZRH–DXB crosses the active Middle East advisory zone.",
    "DXB–BKK departure is clean and high-frequency.",
    "Emirates hub at DXB provides excellent Southeast Asia connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Zurich → Bangkok (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# ZURICH → SINGAPORE
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: zrh.id, destination_city_id: sin.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Singapore Airlines (SQ) · ZRH–IST–SIN",
  path_geojson: line.([[zrh.lng, zrh.lat], [ist.lng, ist.lat], [sin.lng, sin.lat]]),
  distance_km: 10000, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest ZRH→SIN corridor. Turkish Airlines via Istanbul avoids Gulf advisory zone exposure. IST–SIN is a well-operated long-haul segment.",
  ranking_context: "Top option for ZRH→SIN: avoids the advisory zone. TK has reliable ZRH–IST coverage.",
  watch_for: "Monitor Turkish Airlines IST operations. ZRH–IST–SIN has good weekly frequency.",
  explanation_bullets: [
    "ZRH–IST is a clean short European hop.",
    "IST–SIN routes east with near-zone peripheral exposure only.",
    "Turkish Airlines provides efficient ZRH–IST–SIN itineraries."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: zrh.id, destination_city_id: sin.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) + Singapore Airlines (SQ) · ZRH–DXB–SIN daily",
  path_geojson: line.([[zrh.lng, zrh.lat], [dxb.lng, dxb.lat], [sin.lng, sin.lat]]),
  distance_km: 10600, typical_duration_minutes: 800, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. ZRH–DXB crosses the advisory zone. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: ZRH–DXB advisory zone crossing. Emirates provides excellent DXB–SIN frequency.",
  watch_for: "ZRH–DXB transits the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "ZRH–DXB crosses the active Middle East advisory zone.",
    "DXB–SIN departure is clean and very high-frequency.",
    "Emirates hub provides excellent SIN connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Zurich → Singapore (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# BANGKOK → ZURICH  (reverse)
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: zrh.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · BKK–IST–ZRH daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [ist.lng, ist.lat], [zrh.lng, zrh.lat]]),
  distance_km: 8300, typical_duration_minutes: 645, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest BKK→ZRH corridor. Turkish Airlines via Istanbul avoids Gulf advisory zone. IST–ZRH is a clean short European arrival.",
  ranking_context: "Top option for BKK→ZRH: avoids the advisory zone. TK has strong BKK–IST–ZRH frequency.",
  watch_for: "Monitor Turkish Airlines IST operations. BKK–IST–ZRH has good frequency and rebooking depth.",
  explanation_bullets: [
    "BKK–IST routes northwest with near-zone peripheral exposure only.",
    "IST–ZRH is clean standard European routing.",
    "Turkish Airlines provides efficient BKK–IST–ZRH connections."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: bkk.id, destination_city_id: zrh.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · BKK–DXB–ZRH daily",
  path_geojson: line.([[bkk.lng, bkk.lat], [dxb.lng, dxb.lat], [zrh.lng, zrh.lat]]),
  distance_km: 8900, typical_duration_minutes: 695, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. DXB–ZRH crosses the active advisory zone on the European arrival leg. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: DXB–ZRH advisory zone crossing. Emirates provides strong BKK–DXB frequency.",
  watch_for: "DXB–ZRH European arrival leg crosses the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "BKK–DXB departure is clean and high-frequency.",
    "DXB–ZRH crosses the active Middle East advisory zone.",
    "Emirates hub at DXB provides strong rebooking options."
  ],
  calculated_at: now
})

IO.puts("  ✓ Bangkok → Zurich (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# SINGAPORE → ZURICH  (reverse)
# Two families: Turkey hub (IST) · Gulf (DXB)
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: zrh.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) + Singapore Airlines (SQ) · SIN–IST–ZRH",
  path_geojson: line.([[sin.lng, sin.lat], [ist.lng, ist.lat], [zrh.lng, zrh.lat]]),
  distance_km: 10000, typical_duration_minutes: 760, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 1, complexity_score: 0, operational_score: 0,
  recommendation_text: "Cleanest SIN→ZRH corridor. Turkish Airlines via Istanbul avoids the Gulf advisory zone. IST–ZRH is a clean standard European arrival.",
  ranking_context: "Top option for SIN→ZRH: avoids the advisory zone. TK has strong SIN–IST frequency.",
  watch_for: "Monitor Turkish Airlines IST operations. SIN–IST–ZRH has good frequency.",
  explanation_bullets: [
    "SIN–IST routes northwest with near-zone peripheral exposure only.",
    "IST–ZRH is clean standard European routing.",
    "Turkish Airlines and SQ both operate SIN–IST legs reliably."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: sin.id, destination_city_id: zrh.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) + Singapore Airlines (SQ) · SIN–DXB–ZRH daily",
  path_geojson: line.([[sin.lng, sin.lat], [dxb.lng, dxb.lat], [zrh.lng, zrh.lat]]),
  distance_km: 10600, typical_duration_minutes: 800, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai. DXB–ZRH crosses the advisory zone on the European arrival leg. Use when Istanbul timing doesn't work.",
  ranking_context: "Ranked below Istanbul: DXB–ZRH advisory zone crossing. Emirates provides excellent SIN–DXB frequency.",
  watch_for: "DXB–ZRH European arrival leg crosses the advisory zone. Monitor Emirates operational alerts.",
  explanation_bullets: [
    "SIN–DXB departure is clean and very high-frequency.",
    "DXB–ZRH crosses the active Middle East advisory zone.",
    "Emirates hub at DXB is world-class for European connectivity."
  ],
  calculated_at: now
})

IO.puts("  ✓ Singapore → Zurich (2 corridor families: IST, DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# NEW YORK → DELHI
# Three families: central_asia (Air India direct) · Turkey hub · Gulf (Dubai)
# Via Istanbul ranks best: avoids advisory zone; direct has sole-corridor risk;
# Via Dubai carries Gulf advisory exposure.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: jfk.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Air India Direct (Central Asian Routing)",
  carrier_notes: "Air India (AI) · daily JFK–DEL non-stop",
  path_geojson: line.([[jfk.lng, jfk.lat], [-40.0, 55.0], [0.0, 52.0], [30.0, 48.0], [55.0, 44.0], [del.lng, del.lat]]),
  distance_km: 11750, typical_duration_minutes: 875, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Air India's JFK–DEL nonstop uses the Central Asian corridor post-2022. The fastest single-ticket option, but it carries sole-corridor dependency — the entire route goes through Central Asian airspace with no alternative path if the corridor is restricted.",
  ranking_context: "Weakest structural option due to 3/3 corridor dependency. Fastest when the corridor is clear; most vulnerable to schedule disruption when Eurocontrol flow restrictions are active. Via Istanbul offers better structural resilience at comparable or slightly longer travel time.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before departure. Air India is the sole carrier on this direct routing — rebooking onto an alternative means switching to a connecting itinerary from New York.",
  explanation_bullets: [
    "Sole-corridor dependency (3/3) — the entire JFK–DEL sector uses the Central Asian corridor with no viable alternative path if it is restricted.",
    "Air India operates JFK–DEL as a nonstop, meaning that if delayed, rerouting requires switching to a connecting flight from New York.",
    "Post-2022, Air India rerouted away from the Russia/Siberia arc — current Central Asian routing adds approximately one hour compared to pre-2022 schedules.",
    "Journey approximately 14.5 hours. No hub connection risk, but minimal flexibility if the corridor experiences restrictions on your travel day.",
    "Air India frequency on JFK–DEL is limited — rebooking onto a later Air India direct is the primary contingency, and that may mean a full-day delay."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: jfk.id, destination_city_id: del.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · daily JFK–IST–DEL",
  path_geojson: line.([[jfk.lng, jfk.lat], [-30.0, 52.0], [ist.lng, ist.lat], [55.0, 40.0], [del.lng, del.lat]]),
  distance_km: 13500, typical_duration_minutes: 1080, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Better structural balance than Air India direct. Turkish Airlines provides solid JFK–IST frequency, and IST–DEL avoids the Gulf advisory zone. The hub break at Istanbul creates a natural reroute decision point before the second leg.",
  ranking_context: "Ranks above direct (better structural resilience from hub break) and above Dubai (avoids Gulf advisory zone on the inbound leg). Hub dependency at IST adds missed-connection risk not present in the direct option — offset by the corridor flexibility the hub break provides.",
  watch_for: "IST–DEL second leg routes through Central Asian airspace south of the advisory zone — peripheral level-1 exposure. Turkish Airlines JFK–IST: verify current schedule and minimum connection time at IST (typically 1.5–2 hours).",
  explanation_bullets: [
    "Hub break at Istanbul creates a real decision point: if conditions deteriorate on the Central Asian corridor, you can reassess at IST rather than being committed mid-flight.",
    "Corridor dependency rated 2/3 (not 3/3 like direct) because the Istanbul hub provides structural flexibility on the second leg.",
    "Turkish Airlines operates JFK–IST with good frequency and multiple daily IST–DEL connections — combined rebooking depth is reasonable.",
    "IST hub scores 1/3 due to regional proximity — operationally stable throughout the current period, but warrants monitoring.",
    "Total journey approximately 18 hours with a standard Istanbul layover — longer than Air India direct but structurally more resilient."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: jfk.id, destination_city_id: del.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · multiple daily JFK–DXB–DEL",
  path_geojson: line.([[jfk.lng, jfk.lat], [-20.0, 45.0], [30.0, 38.0], [dxb.lng, dxb.lat], [del.lng, del.lat]]),
  distance_km: 12500, typical_duration_minutes: 1080, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates provides the strongest rebooking depth of the three options, but JFK–DXB transits the Middle East advisory zone on approach to Dubai. Use when Istanbul is sold out or disrupted; treat as a contingency rather than a primary choice.",
  ranking_context: "Ranks below Istanbul because the JFK–DXB leg crosses the advisory zone (airspace_score 2). Scores above Air India direct on structural grounds — Emirates' DXB hub and high frequency give rebooking options that the direct option lacks.",
  watch_for: "JFK–DXB transits the Middle East advisory zone on the inbound approach to Dubai. Monitor EASA advisories. Emirates operates multiple daily JFK–DXB departures — strongest rebooking depth of the three options if the outbound JFK departure is disrupted.",
  explanation_bullets: [
    "JFK–DXB first leg crosses the North Atlantic cleanly; the advisory zone exposure is concentrated on the final approach into UAE through the Iraq FIR.",
    "Emirates operates multiple daily JFK–DXB departures — the best first-leg rebooking depth of the three JFK–DEL options.",
    "DXB–DEL is a short, clean segment (~3 hours) with no active advisory zone concerns.",
    "Composite score capped at 60 due to advisory zone transit on the first leg — structural strength of the direct routing cannot compensate for airspace exposure.",
    "Best chosen when maximum rebooking flexibility matters more than airspace exposure, or when Istanbul connections are unavailable."
  ],
  calculated_at: now
})

IO.puts("  ✓ New York → Delhi (3 corridor families: central_asia/Air India, turkey_hub/IST, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# NEW YORK → DUBAI
# Two families: iran_iraq_direct (northern) · egypt_saudi_direct (southern)
# Mirrors London → Dubai structure — same FIR exposure story, longer Atlantic leg.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: jfk.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "iran_iraq_direct",
  route_name: "Northern Routing via Turkey/Iraq FIR",
  carrier_notes: "Emirates (EK) · daily JFK–DXB non-stop; American Airlines (AA) · JFK–DXB",
  path_geojson: line.([[jfk.lng, jfk.lat], [-20.0, 50.0], [15.0, 46.0], [35.0, 37.0], [dxb.lng, dxb.lat]]),
  distance_km: 11000, typical_duration_minutes: 750, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 0, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The dominant JFK–DXB routing goes north over the Atlantic then traverses Turkey and Iraq FIR before descending into UAE airspace. Emirates and American Airlines both operate this corridor. Fastest geometry; carries elevated advisory zone exposure on the final approach to Dubai. Preferred on time; monitor before departure when regional tensions are elevated.",
  ranking_context: "Composite score capped at 60 due to Middle East advisory zone transit approaching DXB — same cap logic as London–Dubai northern routing. The southern alternative trades 15–20 minutes for meaningfully cleaner airspace.",
  watch_for: "Final approach to DXB traverses Iraq FIR (ORBB) and skirts Iranian FIR (OIIX) — the same advisory exposure as London–Dubai northern routing, with a longer Atlantic transit before it. Monitor EASA and FAA NOTAMs before departure.",
  explanation_bullets: [
    "JFK–DXB crosses the North Atlantic cleanly; advisory zone exposure is concentrated on the final descent through Turkey and Iraq FIR into UAE.",
    "Emirates and American Airlines both operate JFK–DXB nonstop — strong combined frequency and rebooking depth.",
    "Fastest JFK–DXB routing (~12h); the Iraq FIR transit is operationally routine but adds formal advisory zone exposure.",
    "Composite capped at 60 due to Middle East advisory zone transit. Southern routing avoids this at the cost of approximately 15–20 minutes additional flying time."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: jfk.id, destination_city_id: dxb.id, via_hub_city_id: nil,
  corridor_family: "egypt_saudi_direct",
  route_name: "Southern Routing via Mediterranean/Egypt/Saudi FIR",
  carrier_notes: "Emirates (EK) · ad-hoc southern routing; charter operators",
  path_geojson: line.([[jfk.lng, jfk.lat], [-15.0, 42.0], [10.0, 35.0], [30.0, 27.0], [dxb.lng, dxb.lat]]),
  distance_km: 11500, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 1,
  recommendation_text: "Southern JFK–DXB alternative routes via the Mediterranean, Egypt FIR, and Saudi FIR — avoids Iraq FIR entirely and stays well clear of Iranian airspace. Adds roughly 15–20 minutes versus the northern routing but reduces advisory zone exposure. Fewer scheduled carriers file this path from New York; more common on charter operations.",
  ranking_context: "Preferred when EASA or FAA bulletins flag elevated Iraq or Iran advisory activity. Operationally correct but not routinely filed as a scheduled service from JFK — most mainline carriers default to the northern routing.",
  watch_for: "Egypt FIR (HECC) and Saudi FIR (OEJD) are operationally stable. Monitor Saudi NOTAMs during major religious events. Confirm with your carrier whether they file the southern routing before relying on it.",
  explanation_bullets: [
    "Routes south across the Mediterranean and east through Egypt FIR — avoids Iraq FIR and Iranian FIR entirely.",
    "Red Sea and Saudi FIR approach into UAE stays well clear of the ICAO Middle East advisory zone core.",
    "Adds ~15–20 minutes over the northern routing; a worthwhile trade when advisory notices are active.",
    "Fewer scheduled carriers file this path from JFK than from London — primarily ad-hoc and charter operations from the New York end."
  ],
  calculated_at: now
})

IO.puts("  ✓ New York → Dubai (2 corridor families: iran_iraq_direct/northern, egypt_saudi_direct/southern)")

# ─────────────────────────────────────────────────────────────────────────────
# TORONTO → DELHI
# Three families: central_asia (Air India direct) · Turkey hub · Gulf (Dubai)
# Same corridor structure as New York → Delhi; YYZ-specific carrier notes.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: yyz.id, destination_city_id: del.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Air India Direct (Central Asian Routing)",
  carrier_notes: "Air India (AI) · YYZ–DEL non-stop service",
  path_geojson: line.([[yyz.lng, yyz.lat], [-35.0, 56.0], [5.0, 53.0], [35.0, 48.0], [60.0, 44.0], [del.lng, del.lat]]),
  distance_km: 11400, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 3, hub_score: 0, complexity_score: 1, operational_score: 1,
  recommendation_text: "Air India's YYZ–DEL nonstop is one of the world's busiest diaspora routes. Post-2022, it uses the Central Asian corridor — faster total travel time than any connecting option, but sole-corridor dependency means high schedule variance if the corridor is restricted.",
  ranking_context: "Weakest structural option due to 3/3 corridor dependency. The Canada–India diaspora corridor generates very high demand — Air India capacity is often constrained; book well in advance. Via Istanbul offers better structural resilience at a longer total travel time.",
  watch_for: "Check Eurocontrol ATFM status for the Central Asian corridor before departure. Air India frequency on YYZ–DEL is meaningful for this pair but rebooking onto a later direct departure may mean a full-day wait.",
  explanation_bullets: [
    "Sole-corridor dependency (3/3) — the entire YYZ–DEL sector uses the Central Asian corridor with no viable alternative path if it is restricted.",
    "Air India operates YYZ–DEL as a high-demand diaspora route. Capacity is often full — missed connections require rebooking onto connecting itineraries.",
    "Post-2022, Air India rerouted away from the Russia/Siberia arc. Current Central Asian routing runs approximately 14 hours.",
    "Journey approximately 14 hours. No hub connection risk, but minimal flexibility if the corridor is restricted on your travel day.",
    "Toronto to Delhi is one of Canada's highest-traffic international pairs by passenger volume — book early and monitor Central Asian ATFM status."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: yyz.id, destination_city_id: del.id, via_hub_city_id: ist.id,
  corridor_family: "turkey_hub",
  route_name: "Via Istanbul",
  carrier_notes: "Turkish Airlines (TK) · YYZ–IST–DEL",
  path_geojson: line.([[yyz.lng, yyz.lat], [-25.0, 52.0], [ist.lng, ist.lat], [55.0, 40.0], [del.lng, del.lat]]),
  distance_km: 13000, typical_duration_minutes: 1080, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Better structural balance than Air India direct. Turkish Airlines provides YYZ–IST service, and IST–DEL avoids the Gulf advisory zone. The hub break at Istanbul creates a reroute decision point before committing to the second leg.",
  ranking_context: "Ranks above Air India direct (better structural resilience) and above Dubai (avoids Gulf advisory zone). Hub dependency at IST adds connection risk offset by the corridor flexibility the hub break provides.",
  watch_for: "IST–DEL second leg routes through Central Asian airspace south of the advisory zone — peripheral level-1 exposure. Turkish Airlines YYZ–IST: verify current schedule. Minimum connection time at IST is typically 1.5–2 hours.",
  explanation_bullets: [
    "Hub break at Istanbul creates a natural decision point — if Central Asian corridor conditions change, you can reassess before the IST–DEL second leg.",
    "Corridor dependency rated 2/3 (not 3/3 like direct) because the Istanbul hub creates structural flexibility on the second leg.",
    "Turkish Airlines YYZ–IST and IST–DEL connections give adequate combined frequency and rebooking options.",
    "IST hub scores 1/3 due to regional proximity — operationally stable throughout the current advisory period.",
    "Total journey approximately 18 hours with Istanbul layover. Longer than Air India direct but structurally more resilient."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: yyz.id, destination_city_id: del.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · daily YYZ–DXB–DEL",
  path_geojson: line.([[yyz.lng, yyz.lat], [-15.0, 45.0], [30.0, 38.0], [dxb.lng, dxb.lat], [del.lng, del.lat]]),
  distance_km: 12200, typical_duration_minutes: 1050, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "Emirates via Dubai provides strong rebooking depth, but YYZ–DXB transits the Middle East advisory zone on approach to Dubai. Use when Istanbul is sold out or disrupted; treat as a contingency rather than a primary choice.",
  ranking_context: "Ranks below Istanbul because the YYZ–DXB leg crosses the advisory zone (airspace_score 2). Ranks above Air India direct on structural grounds — Emirates' DXB hub and high daily frequency give contingency options the direct cannot match.",
  watch_for: "YYZ–DXB transits the Middle East advisory zone on the inbound approach to Dubai. Emirates operates daily YYZ–DXB — strongest rebooking depth of the three options if the outbound is disrupted.",
  explanation_bullets: [
    "YYZ–DXB crosses the Atlantic cleanly; the advisory zone exposure is on the final approach into UAE through the Iraq FIR.",
    "Emirates operates daily YYZ–DXB — the best first-leg rebooking depth of the three YYZ–DEL options.",
    "DXB–DEL is a short (~3 hour), clean segment with no active advisory concerns.",
    "Composite score capped at 60 due to advisory zone transit on the first leg.",
    "Relevant primarily as a contingency when Istanbul connections are unavailable or Central Asian corridor restrictions are confirmed active."
  ],
  calculated_at: now
})

IO.puts("  ✓ Toronto → Delhi (3 corridor families: central_asia/Air India, turkey_hub/IST, gulf_dubai/DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# TORONTO → LONDON
# Two families: direct (North Atlantic nonstop) · atlantic_hub (via Amsterdam)
# Both legs entirely advisory-clean — transatlantic pairs have no Middle East
# exposure. Product story: this route is structurally clean; main risk is NATS.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: yyz.id, destination_city_id: lhr.id, via_hub_city_id: nil,
  corridor_family: "direct",
  route_name: "Air Canada / British Airways Nonstop",
  carrier_notes: "Air Canada (AC) · daily YYZ–LHR non-stop; British Airways (BA) · daily YYZ–LHR",
  path_geojson: line.([[yyz.lng, yyz.lat], [-35.0, 53.0], [lhr.lng, lhr.lat]]),
  distance_km: 5700, typical_duration_minutes: 420, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The clean transatlantic option. YYZ–LHR routes over the North Atlantic via NATS oceanic tracks — entirely outside all active airspace advisory zones. Air Canada and British Airways both operate nonstop service. Low disruption risk; the primary variance factor is oceanic track weather, not geopolitical.",
  ranking_context: "Top-ranked option: no advisory zone exposure, no hub dependency. The North Atlantic Track System is outside all active Middle East advisory zones. Disruption risk is weather and NATS congestion, not corridor politics.",
  watch_for: "North Atlantic Track System (NATS) can impose slot restrictions in severe weather. Check NATS forecast and Eurocontrol slot status before departure. No Middle East advisory zone concerns on this routing.",
  explanation_bullets: [
    "No advisory zone exposure on either direction of this routing — entirely clean North Atlantic crossing.",
    "Air Canada and British Airways both operate daily YYZ–LHR nonstop with combined strong rebooking options.",
    "Journey approximately 7 hours eastbound. The clean airspace profile means disruption risk is oceanic weather, not geopolitical.",
    "Toronto (YYZ) is Canada's primary international hub with strong carrier infrastructure for rerouting if needed."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: yyz.id, destination_city_id: lhr.id, via_hub_city_id: ams.id,
  corridor_family: "atlantic_hub",
  route_name: "Via Amsterdam",
  carrier_notes: "Air Canada (AC) + KLM (KL) · YYZ–AMS–LHR",
  path_geojson: line.([[yyz.lng, yyz.lat], [-35.0, 53.0], [ams.lng, ams.lat], [lhr.lng, lhr.lat]]),
  distance_km: 6400, typical_duration_minutes: 540, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "KLM via Amsterdam adds a European hub break. Both legs are clean North Atlantic and Intra-European — no advisory zone exposure anywhere on this routing. Adds 2–3 hours total travel time versus direct; most useful when direct is sold out or AMS is the actual destination.",
  ranking_context: "Ranks below direct: same clean airspace but hub dependency and longer total journey. The via-AMS option is most relevant when YYZ–LHR nonstop is unavailable or Amsterdam Schiphol is the intended stopover.",
  watch_for: "AMS–LHR is a very short European hop (~1 hour). Minimum connection time at AMS is typically 40 minutes for Schengen connections. Confirm KLM schedule for adequate connection window.",
  explanation_bullets: [
    "No advisory zone exposure on either leg — YYZ–AMS and AMS–LHR are both clean advisory-free routes.",
    "KLM and Air Canada provide adequate combined frequency on the YYZ–AMS segment.",
    "AMS–LHR is a high-frequency European shuttle — clean, short, and well-connected.",
    "Adds approximately 2–3 hours total versus nonstop due to the Amsterdam connection. Choose when direct availability is constrained."
  ],
  calculated_at: now
})

IO.puts("  ✓ Toronto → London (2 corridor families: direct/nonstop, atlantic_hub/via AMS)")

# ─────────────────────────────────────────────────────────────────────────────
# LOS ANGELES → TOKYO
# Two families: pacific_direct (nonstop transpacific) · north_asia_icn (via Seoul)
# Both legs entirely advisory-clean — Pacific routing has no Middle East exposure.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lax.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "pacific_direct",
  route_name: "Transpacific Nonstop",
  carrier_notes: "Japan Airlines (JL) · daily LAX–NRT; ANA (NH) · daily LAX–NRT; United (UA) · daily LAX–NRT",
  path_geojson: line.([[lax.lng, lax.lat], [-150.0, 42.0], [-175.0, 46.0], [165.0, 44.0], [nrt.lng, nrt.lat]]),
  distance_km: 8760, typical_duration_minutes: 660, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "The standard LAX–NRT routing crosses the North Pacific — entirely advisory-clean with no active airspace concerns on any segment. JAL, ANA, and United all operate this corridor daily with strong combined frequency and rebooking depth. Preferred choice for most LAX–NRT travellers.",
  ranking_context: "Top-ranked LAX–NRT option: no advisory zone exposure, no hub dependency. Multiple daily departures across three major carriers. Via Seoul adds a strong hub break but at the cost of slightly longer total travel time.",
  watch_for: "Pacific routing is advisory-clean. Primary disruption risks are severe weather over the North Pacific (winter months) and Eurocontrol upstream delays on connecting traffic. No Middle East advisory zone concerns.",
  explanation_bullets: [
    "Clean transpacific routing — no active airspace advisory zones on any segment of the LAX–NRT path.",
    "JAL, ANA, and United operate LAX–NRT nonstop with 3+ daily combined departures. Strongest rebooking depth of any LAX–NRT corridor.",
    "Journey approximately 11 hours westbound. Pacific crossing in winter may add 30–45 minutes due to jet stream headwinds.",
    "Pre-2022, some NRT–LAX eastbound routings used a polar arc via Alaska. The westbound LAX–NRT transpacific routing is unaffected by the Russian airspace closure."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lax.id, destination_city_id: nrt.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · daily LAX–ICN–NRT; Asiana (OZ) · LAX–ICN–NRT",
  path_geojson: line.([[lax.lng, lax.lat], [-150.0, 40.0], [-175.0, 44.0], [icn.lng, icn.lat], [nrt.lng, nrt.lat]]),
  distance_km: 9500, typical_duration_minutes: 840, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Korean Air and Asiana via Seoul add a world-class North Asian hub break between Los Angeles and Tokyo. ICN is world-class (hub_score 0/3); the ICN–NRT second leg is only 2 hours over clean airspace. Useful when nonstop options are sold out or for onward connections beyond NRT.",
  ranking_context: "Clean airspace on both legs. Ranks below direct because hub dependency adds total journey time and missed-connection risk. ICN hub quality (score 0/3) is excellent — the structural penalty is hub dependency alone, not airspace exposure.",
  watch_for: "LAX–ICN uses the transpacific corridor — no advisory zone concerns. ICN–NRT is 2 hours over clean Korean/Japanese airspace. No advisory concerns on either leg.",
  explanation_bullets: [
    "Clean Pacific airspace on both legs — no advisory zone exposure at any segment.",
    "ICN hub scores 0/3 (world-class) with very high ICN–NRT frequency across Korean Air, ANA, and JAL.",
    "The ICN–NRT second leg is only ~2 hours — much shorter than any alternative second leg to Tokyo from a US West Coast departure.",
    "Korean Air and Asiana provide strong LAX–ICN frequency. Hub break at Seoul is most useful for connecting to other Korean or Japanese cities."
  ],
  calculated_at: now
})

IO.puts("  ✓ Los Angeles → Tokyo (2 corridor families: pacific_direct/nonstop, north_asia_icn/via ICN)")

# ─────────────────────────────────────────────────────────────────────────────
# VANCOUVER → TOKYO
# Two families: pacific_direct (Air Canada nonstop) · north_asia_icn (via Seoul)
# YVR is Canada's Pacific gateway — shortest transpacific from a Canadian hub.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: yvr.id, destination_city_id: nrt.id, via_hub_city_id: nil,
  corridor_family: "pacific_direct",
  route_name: "Air Canada Transpacific Nonstop",
  carrier_notes: "Air Canada (AC) · daily YVR–NRT non-stop",
  path_geojson: line.([[yvr.lng, yvr.lat], [-155.0, 51.0], [-175.0, 51.0], [160.0, 47.0], [nrt.lng, nrt.lat]]),
  distance_km: 7560, typical_duration_minutes: 570, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 0, operational_score: 0,
  recommendation_text: "Air Canada's YVR–NRT nonstop takes the shortest transpacific path from any major Canadian hub. Entirely advisory-clean — no Middle East airspace concerns. At approximately 9.5 hours, it is one of the shortest transatlantic flights from North America to Japan.",
  ranking_context: "Top-ranked YVR–NRT option: no advisory zone exposure, no hub dependency. Vancouver's Pacific position gives it a shorter Japan routing than any other Canadian city. Via Seoul adds hub flexibility but at the cost of total travel time.",
  watch_for: "North Pacific routing is advisory-clean. Primary disruption factor is winter weather over the Pacific. No Middle East advisory zone concerns on any segment.",
  explanation_bullets: [
    "Clean transpacific routing — no advisory zone exposure on any segment.",
    "Air Canada operates daily YVR–NRT nonstop. Vancouver's Pacific geography gives it the shortest Canadian transpacific arc to Japan.",
    "Journey approximately 9.5 hours westbound — shorter than any comparable North American departure east of the Rockies.",
    "YVR–NRT westbound is unaffected by the Russian airspace closure; the Pacific routing does not overfly Russian territory."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: yvr.id, destination_city_id: nrt.id, via_hub_city_id: icn.id,
  corridor_family: "north_asia_icn",
  route_name: "Via Seoul",
  carrier_notes: "Korean Air (KE) · YVR–ICN–NRT; Air Canada (AC) + Korean Air (KE) codeshare",
  path_geojson: line.([[yvr.lng, yvr.lat], [-150.0, 48.0], [-175.0, 49.0], [icn.lng, icn.lat], [nrt.lng, nrt.lat]]),
  distance_km: 8300, typical_duration_minutes: 780, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 0, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Korean Air via Seoul adds the world-class ICN hub between Vancouver and Tokyo. Both legs are clean Pacific and Korean/Japanese airspace. The ICN–NRT second leg is only 2 hours. Most relevant when Air Canada nonstop is unavailable or for connections beyond NRT.",
  ranking_context: "Clean airspace on both legs. Ranks below direct because hub dependency adds connection risk and total journey time. ICN hub quality (0/3) is excellent; the only structural cost is the hub connection itself.",
  watch_for: "YVR–ICN uses the transpacific corridor — no advisory zone concerns. ICN–NRT is 2 hours over clean Korean/Japanese airspace.",
  explanation_bullets: [
    "Clean Pacific airspace on both legs — no advisory zone exposure anywhere.",
    "ICN hub scores 0/3 (world-class) with very high ICN–NRT frequency.",
    "ICN–NRT is only ~2 hours — the short second leg limits connection exposure.",
    "Korean Air and Air Canada codeshare gives reasonable combined frequency on the YVR–ICN segment."
  ],
  calculated_at: now
})

IO.puts("  ✓ Vancouver → Tokyo (2 corridor families: pacific_direct/nonstop, north_asia_icn/via ICN)")

# ─────────────────────────────────────────────────────────────────────────────
# LONDON → BEIJING
# Two families: central_asia (Air China/BA direct) · gulf_dubai (via DXB)
# Russia closure story applied directly to Europe–China routing.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: pek.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Air China / BA Direct (Central Asian Routing)",
  carrier_notes: "Air China (CA) · daily LHR–PEK non-stop; British Airways (BA) · LHR–PEK",
  path_geojson: line.([[lhr.lng, lhr.lat], [25.0, 50.0], [55.0, 48.0], [85.0, 45.0], [pek.lng, pek.lat]]),
  distance_km: 9200, typical_duration_minutes: 750, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Air China and British Airways both operate LHR–PEK nonstop via the Central Asian corridor. Post-2022, this route is approximately 2 hours longer than pre-2022 schedules due to the Russian airspace closure. The Central Asian corridor is the only viable direct routing and carries peripheral advisory proximity but no active zone transit.",
  ranking_context: "Best-rated LHR–PEK option. No Gulf advisory zone exposure; both carriers provide reasonable combined frequency. The via-Dubai alternative adds advisory zone exposure and hub complexity with no routing benefit for this pair.",
  watch_for: "LHR–PEK uses the Central Asian corridor — check Eurocontrol ATFM status before departure. Air China operates daily LHR–PEK; British Airways also serves this pair. Post-Russia closure, this routing adds approximately 2 hours versus pre-2022 schedules.",
  explanation_bullets: [
    "Central Asian corridor is the only viable direct routing since Russian airspace closure in 2022 — no Siberian arc available.",
    "Air China and British Airways both operate nonstop LHR–PEK — good combined rebooking depth on a pair not served by many carriers.",
    "LHR–PEK pre-2022 was approximately 10 hours via Russia/Siberia. Current Central Asian routing runs 12–13 hours.",
    "Airspace corridor rated 2/3 — the Central Asian arc has some routing sub-path flexibility, but all viable paths traverse the same general corridor.",
    "Beijing (PEK) is China's primary international gateway with strong onward domestic connectivity."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: lhr.id, destination_city_id: pek.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · LHR–DXB–PEK",
  path_geojson: line.([[lhr.lng, lhr.lat], [25.0, 40.0], [dxb.lng, dxb.lat], [80.0, 30.0], [pek.lng, pek.lat]]),
  distance_km: 11000, typical_duration_minutes: 900, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "LHR–DXB–PEK adds advisory zone exposure on the first leg and routes significantly further south before going north to Beijing. Longer and more airspace-exposed than the direct Central Asian option. Use only as a contingency when Central Asian corridor restrictions are confirmed active.",
  ranking_context: "Ranks below direct Central Asian: advisory zone exposure on LHR–DXB first leg plus hub dependency and a longer total journey (~15h vs ~12.5h). Emirates' DXB hub provides frequency and rebooking options as contingency.",
  watch_for: "LHR–DXB first leg transits the active Middle East advisory zone. DXB–PEK routes north through Pakistan and Central Asia — operationally clean but significantly longer than the direct option. Total journey approximately 15 hours.",
  explanation_bullets: [
    "LHR–DXB transits the Middle East advisory zone — carries airspace_score 2 and composite cap of 60.",
    "DXB–PEK routes north through Pakistan and China — clean airspace on the second leg, but the detour adds significant distance.",
    "Total journey is approximately 2.5 hours longer than the direct Central Asian option.",
    "Emirates provides strong LHR–DXB frequency — viable contingency if the Central Asian corridor is confirmed disrupted."
  ],
  calculated_at: now
})

IO.puts("  ✓ London → Beijing (2 corridor families: central_asia/direct, gulf_dubai/via DXB)")

# ─────────────────────────────────────────────────────────────────────────────
# FRANKFURT → SHANGHAI
# Two families: central_asia (Lufthansa/CZ direct) · gulf_dubai (via DXB)
# Russia closure story applied to Germany–China routing. PVG is China's
# primary international business gateway.
# ─────────────────────────────────────────────────────────────────────────────

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: pvg.id, via_hub_city_id: nil,
  corridor_family: "central_asia",
  route_name: "Lufthansa / China Eastern Direct (Central Asian Routing)",
  carrier_notes: "Lufthansa (LH) · FRA–PVG non-stop; China Eastern (MU) · FRA–PVG",
  path_geojson: line.([[fra.lng, fra.lat], [40.0, 48.0], [70.0, 45.0], [95.0, 40.0], [pvg.lng, pvg.lat]]),
  distance_km: 9200, typical_duration_minutes: 720, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 1, corridor_score: 1, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Lufthansa and China Eastern both operate FRA–PVG nonstop via the Central Asian corridor. Post-2022, this route is approximately 1.5–2 hours longer than pre-2022 schedules. The Central Asian corridor is the default routing and carries only peripheral advisory proximity — no active zone transit.",
  ranking_context: "Best-rated FRA–PVG option. No Gulf advisory zone exposure; Lufthansa and China Eastern provide reasonable combined frequency. The via-Dubai alternative adds advisory zone exposure and hub complexity with no routing benefit for this pair.",
  watch_for: "FRA–PVG uses the Central Asian corridor — check Eurocontrol ATFM status before departure. Lufthansa maintains FRA–PVG direct service; China Eastern also operates this pair. Post-Russia closure, journey runs approximately 12 hours.",
  explanation_bullets: [
    "Central Asian corridor is the only viable direct routing for FRA–PVG since Russian airspace closure in 2022.",
    "Lufthansa maintains FRA–PVG direct service; China Eastern also operates on this pair. Combined rebooking options are reasonable.",
    "FRA–PVG via Russia was approximately 10.5 hours pre-2022. Current Central Asian routing runs approximately 12 hours.",
    "Shanghai Pudong (PVG) is China's primary international business gateway — well-connected for onward domestic and regional travel.",
    "Corridor dependency rated 2/3 — Central Asian arc has some routing flexibility within the corridor but no major alternative path."
  ],
  calculated_at: now
})

route = upsert_route.(%{
  origin_city_id: fra.id, destination_city_id: pvg.id, via_hub_city_id: dxb.id,
  corridor_family: "gulf_dubai",
  route_name: "Via Dubai",
  carrier_notes: "Emirates (EK) · FRA–DXB–PVG",
  path_geojson: line.([[fra.lng, fra.lat], [30.0, 37.0], [dxb.lng, dxb.lat], [85.0, 25.0], [pvg.lng, pvg.lat]]),
  distance_km: 12000, typical_duration_minutes: 960, is_active: true, last_reviewed_at: reviewed
})
upsert_score.(route, %{
  airspace_score: 2, corridor_score: 2, hub_score: 1, complexity_score: 1, operational_score: 0,
  recommendation_text: "FRA–DXB–PVG adds advisory zone exposure on the first leg and routes significantly further south before going east to Shanghai. Longer and more airspace-exposed than the direct Central Asian option. Only relevant as contingency when Central Asian corridor restrictions are confirmed active.",
  ranking_context: "Ranks below direct Central Asian: advisory zone exposure on FRA–DXB first leg, hub dependency, and significantly longer total journey (~16h vs ~12h). Emirates operates FRA–DXB and DXB–PVG with strong frequency, making this a viable contingency corridor.",
  watch_for: "FRA–DXB first leg transits the active Middle East advisory zone. DXB–PVG routes east through South Asia and Southeast Asia — operationally clean but significantly longer than the direct option.",
  explanation_bullets: [
    "FRA–DXB transits the Middle East advisory zone — carries airspace_score 2 and composite cap of 60.",
    "DXB–PVG routes east across South Asia — clean airspace on the second leg, but the southern detour adds significant distance and time.",
    "Total journey approximately 4 hours longer than the direct Central Asian option.",
    "Emirates' DXB hub provides strong frequency on both FRA–DXB and DXB–PVG legs — viable contingency if Central Asian corridor is confirmed disrupted."
  ],
  calculated_at: now
})

IO.puts("  ✓ Frankfurt → Shanghai (2 corridor families: central_asia/direct, gulf_dubai/via DXB)")

IO.puts("Seed complete.")
