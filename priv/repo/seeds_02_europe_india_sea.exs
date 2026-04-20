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

