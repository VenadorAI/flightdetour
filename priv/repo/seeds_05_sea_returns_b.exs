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
