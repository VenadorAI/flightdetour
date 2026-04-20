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
  airspace_score: 1, corridor_score: 2, hub_score: 0, complexity_score: 1, operational_score: 0,
  recommendation_text: "Gulf-free routing via Cathay's Hong Kong hub. Longer total journey but cleanest airspace profile of the three options.",
  ranking_context: "Structural score (57) is lower than Istanbul (67) because of the Central Asian corridor dependency and the northward overshoot past Singapore — the LHR–HKG–SIN routing adds roughly 16% vs the great-circle path. Pressure score (71) matches Istanbul exactly: both avoid the advisory zone on all legs. Net composite is Watchful, well clear of the Dubai option (Constrained) which crosses the active advisory zone.",
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

