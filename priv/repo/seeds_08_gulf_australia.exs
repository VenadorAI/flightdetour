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
