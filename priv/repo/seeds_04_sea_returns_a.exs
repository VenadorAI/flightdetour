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

