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

