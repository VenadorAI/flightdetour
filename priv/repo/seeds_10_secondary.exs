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
