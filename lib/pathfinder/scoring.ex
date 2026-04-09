defmodule Pathfinder.Scoring do
  @moduledoc """
  Three-layer disruption scoring engine.

  ## Layers

  ### Layer B — Structural Stability (50% of composite)
  How inherently robust is this corridor, independent of current events?

    corridor_score (45% of structural):
      0 = multiple independent path options
      1 = limited alternatives, one primary corridor
      2 = single narrow corridor with few backup paths
      3 = sole-corridor dependency, no viable alternative

    hub_score (35% of structural):
      0 = world-class hub, excellent resilience and connection depth
          (also used for direct/no-hub flights — no hub dependency)
      1 = major hub, some restriction or regional sensitivity
      2 = limited hub, constrained capacity or regional exposure
      3 = unstable or conflict-proximate hub

    complexity_score (20% of structural):
      0 = direct or near-optimal routing
      1 = minor detour (5–20% longer than great-circle)
      2 = moderate backtrack or significant detour (20–50%)
      3 = severe backtrack or highly indirect routing

  ### Layer C — Current Disruption Pressure (50% of composite)
  What is the active geopolitical and operational environment right now?

    airspace_score (70% of pressure) — weighted heavily because this is the
    primary real-world driver of disruption on affected corridors:
      0 = no restricted or advisory airspace on route
      1 = peripheral advisory proximity; route not directly through restricted zone
      2 = route transits active advisory zone (e.g. Middle East, Iranian FIR)
      3 = route transits active high-intensity conflict zone — hard cap applied

    operational_score (30% of pressure):
      0 = multiple carriers, high frequency, strong rebooking depth
      1 = 2–3 carriers, adequate frequency, some rebooking flexibility
      2 = 1–2 carriers, reduced frequency, limited rebooking options
      3 = single carrier or severely disrupted operations

  ### Caps
  If airspace_score == 3 (direct conflict zone transit):
    pressure_score is capped at 25 regardless of operational factors.

  If airspace_score == 2 (transits active advisory zone):
    composite_score is capped at 60. A route crossing an active advisory
    zone cannot reach the :flowing range regardless of structural factors.
    This prevents direct-routing structural bonuses (no hub, no complexity)
    from inflating advisory-zone routes above lower-exposure alternatives.

  ## Composite
    composite = round(structural_score × 0.50 + pressure_score × 0.50)
    (then caps applied)

  ## Labels
    ≥ 72 → :flowing     (structurally solid, pressure low — no advisory zone transit)
    56–71 → :watchful   (manageable disruption factors, monitor)
    38–55 → :constrained (notable structural or pressure concerns)
    0–37  → :strained   (significant disruption; understand tradeoffs before booking)

  Note: the :flowing threshold was lowered from 75 to 72 to avoid borderline misclassification
  of near-zone (airspace=1) routes with minor detour. Advisory zone (airspace=2) routes
  cannot reach :flowing regardless, because the composite cap of 60 < 72.

  Scoring formula: each layer uses a power-curve penalty — `100 - (raw/3)^0.85 * 100` —
  rather than a strictly linear scale. This amplifies mid-range penalties and widens
  score separation between similar-tier routes without changing boundary conditions
  (raw=0 → 100, raw=3 → 0).
  """

  # --- Public API ---

  def calculate(airspace, corridor, hub, complexity, operational) do
    structural    = structural_score(corridor, hub, complexity)
    pressure      = pressure_score(airspace, operational)
    composite_raw = clamp(round(structural * 0.50 + pressure * 0.50))

    # Continuous tie-breaker: weighted sum of raw integer inputs before any rounding.
    # Lower = less disruption = better route. Used as a secondary sort key so that
    # routes sharing the same displayed composite_score still rank deterministically.
    composite_raw_float =
      (corridor * 0.45 + hub * 0.35 + complexity * 0.20) * 0.50 +
      (airspace * 0.70 + operational * 0.30) * 0.50

    {composite, cap_reason} =
      cond do
        airspace == 3 ->
          {composite_raw,
           "Hard cap applied: route transits an active high-intensity conflict zone. Pressure score ceiling at 25."}
        airspace == 2 and composite_raw > 60 ->
          {60,
           "Advisory zone cap: composite limited to 60. This route transits an active airspace advisory zone — structural factors cannot compensate for active advisory exposure."}
        true ->
          {composite_raw, nil}
      end

    %{
      airspace_score:      airspace,
      corridor_score:      corridor,
      hub_score:           hub,
      complexity_score:    complexity,
      operational_score:   operational,
      structural_score:    structural,
      pressure_score:      pressure,
      composite_score:     composite,
      composite_raw_float: composite_raw_float,
      label:               label_for(composite),
      score_cap_reason:    cap_reason
    }
  end

  def structural_score(corridor, hub, complexity) do
    raw = corridor * 0.45 + hub * 0.35 + complexity * 0.20
    clamp(100 - round(:math.pow(raw / 3.0, 0.85) * 100))
  end

  def pressure_score(airspace, operational) do
    raw   = airspace * 0.70 + operational * 0.30
    score = clamp(100 - round(:math.pow(raw / 3.0, 0.85) * 100))
    if airspace == 3, do: min(score, 25), else: score
  end

  def label_for(score) when score >= 72, do: :flowing
  def label_for(score) when score >= 56, do: :watchful
  def label_for(score) when score >= 38, do: :constrained
  def label_for(_score),                 do: :strained

  # --- Metadata for UI ---

  def score_dimensions, do: [:structural_score, :pressure_score]

  def dimension_label(:structural_score), do: "Structural"
  def dimension_label(:pressure_score),   do: "Current Pressure"
  def dimension_label(:airspace_score),   do: "Airspace"
  def dimension_label(:corridor_score),   do: "Corridor"
  def dimension_label(:hub_score),        do: "Hub"
  def dimension_label(:complexity_score), do: "Route Directness"
  def dimension_label(:operational_score), do: "Carrier Options"

  def dimension_note(:structural_score),
    do: "Corridor alternatives · Hub quality · Route efficiency"
  def dimension_note(:pressure_score),
    do: "Airspace advisories · Carrier depth"

  def factor_dimensions,
    do: [:airspace_score, :corridor_score, :hub_score, :complexity_score, :operational_score]

  def factor_label(0), do: "None"
  def factor_label(1), do: "Low"
  def factor_label(2), do: "Elevated"
  def factor_label(3), do: "High"

  def factor_label_color(0), do: "text-emerald-400/70"
  def factor_label_color(1), do: "text-amber-400/60"
  def factor_label_color(2), do: "text-orange-400/70"
  def factor_label_color(_), do: "text-red-400/70"

  # --- Corridor family helpers ---

  def corridor_family_label("turkey_hub"),        do: "Via Istanbul"
  def corridor_family_label("gulf_dubai"),        do: "Via Dubai"
  def corridor_family_label("gulf_doha"),         do: "Via Doha"
  def corridor_family_label("gulf_auh"),          do: "Via Abu Dhabi"
  def corridor_family_label("central_asia"),      do: "Central Asian corridor"
  def corridor_family_label("north_asia_hkg"),    do: "Via Hong Kong"
  def corridor_family_label("north_asia_icn"),    do: "Via Seoul"
  def corridor_family_label("china_arc"),         do: "Via Beijing"
  def corridor_family_label("south_asia_direct"), do: "South Asia direct"
  def corridor_family_label("direct"),            do: "Direct"
  def corridor_family_label("pacific_direct"),    do: "Transpacific direct"
  def corridor_family_label("atlantic_hub"),      do: "Via North Atlantic hub"
  def corridor_family_label(_),                   do: "Other"

  # --- Route decision helpers ---

  # Returns the dominant weakness in plain traveler language.
  def main_weakness(score) do
    cond do
      score.airspace_score == 3 -> "Flies through an active conflict zone"
      score.airspace_score == 2 -> "First or second leg crosses the active Middle East advisory zone"
      score.corridor_score == 3 -> "Entire route depends on one corridor — no backup if it's restricted"
      score.hub_score == 3 -> "Connecting hub is close to an active conflict zone"
      score.corridor_score == 2 -> "Limited alternative paths if the main corridor is disrupted"
      score.hub_score == 2 -> "Hub has capacity or regional constraints"
      score.operational_score == 3 -> "Very few airlines operate this — hard to rebook if disrupted"
      score.operational_score == 2 -> "Few carriers on this corridor"
      score.complexity_score >= 2 -> "Route adds significant distance vs the most direct path"
      score.airspace_score == 1 -> "Route passes near an advisory zone (not through it)"
      true -> nil
    end
  end

  # Returns {label, text_color_class} for corridor fallback strength.
  def fallback_strength(0), do: {"Strong", "text-emerald-400/80"}
  def fallback_strength(1), do: {"Moderate", "text-amber-400/80"}
  def fallback_strength(2), do: {"Weak", "text-orange-400/80"}
  def fallback_strength(_), do: {"Very weak", "text-red-400/80"}

  # Returns a short role label for a route — communicates WHY this option exists.
  # Roles describe the route's inherent value: what tradeoff it makes,
  # not a ranking relative to other routes shown (which changes per pair).
  def route_role(route) do
    score = route.score
    cf = route.corridor_family
    cond do
      is_nil(score) -> nil
      # Central Asian corridor direct
      cf == "central_asia" and score.corridor_score >= 3 -> "Fastest if clear"
      cf == "central_asia" -> "Fastest, variable"
      # Istanbul hub: best structural balance, avoids Gulf
      cf == "turkey_hub" and score.composite_score >= 70 -> "Best balance"
      cf == "turkey_hub" -> "Avoids Gulf airspace"
      # Gulf hubs: high frequency, advisory exposure
      cf == "gulf_dubai" -> "Most rebook options"
      cf == "gulf_doha" -> "Gulf alternative"
      cf == "gulf_auh" -> "Gulf alternative"
      # East Asian hubs: Gulf-free longer routing
      cf == "north_asia_hkg" and score.airspace_score <= 1 -> "Gulf-free routing"
      cf == "north_asia_hkg" -> "East Asia routing"
      cf == "north_asia_icn" and score.airspace_score <= 1 -> "Gulf-free · short final"
      cf == "north_asia_icn" -> "Via Seoul"
      # China-side arc: mainland China hub connection
      cf == "china_arc" -> "China-side routing"
      # Pacific and Atlantic clean routings
      cf == "pacific_direct" -> "Clean Pacific routing"
      cf == "atlantic_hub" -> "Atlantic hub"
      # Direct
      cf == "direct" and score.airspace_score == 0 -> "No connections"
      cf == "direct" and score.airspace_score >= 2 -> "Fastest · Gulf corridor"
      cf == "direct" -> "No stops"
      # Singapore/Southeast Asia hub: natural geographic waypoint
      cf == "south_asia_direct" and score.airspace_score <= 1 -> "Natural waypoint"
      cf == "south_asia_direct" -> "Most direct"
      true -> nil
    end
  end

  defp clamp(n), do: n |> max(0) |> min(100)
end
