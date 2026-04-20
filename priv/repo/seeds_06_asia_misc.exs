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
