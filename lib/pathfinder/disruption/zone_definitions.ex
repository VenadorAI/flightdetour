defmodule Pathfinder.Disruption.ZoneDefinitions do
  @moduledoc """
  Canonical definitions for all disruption zones.

  ## How to update advisories

  This is the only file that needs editing to update zone status, severity,
  or text copy. After editing, re-run seeds to apply:

      mix run priv/repo/seeds.exs

  Fields updated most frequently:
    - `status`         — :active | :monitoring | :resolved
    - `severity`       — :low | :moderate | :high | :critical
    - `summary_text`   — human-readable one-sentence status
    - `last_updated_at` — set to current UTC datetime when making changes

  Fields used by the freshness/advisory monitoring system:
    - `source_name` — human-readable label for the source (e.g. "EASA SIB 2022-10")
    - `source_url`  — the page URL monitored by EASAChecker for content changes.
                      The checker groups zones by URL so each unique URL is fetched
                      once per run. Set to nil to exclude a zone from monitoring.

  Fields that rarely change:
    - `boundary_geojson` — geographic polygon (update only if zone expands/contracts)
    - `affected_regions` — region labels shown in UI
    - `slug`             — stable identifier used by route seeds (do not change)
  """

  # Primary EASA conflict zones index — monitored for any SIB update
  @easa_conflict_zones_url "https://www.easa.europa.eu/en/domains/operations/air-operations/safety-information-bulletins-conflict-zones-sib"

  # Eurocontrol assessment of Russia/Ukraine war impact on European aviation
  @eurocontrol_cfa_url "https://www.eurocontrol.int/publication/eurocontrol-comprehensive-assessment-impact-russia-ukraine-war-european-aviation"

  @zones [
    %{
      name: "Russian Airspace Closure",
      slug: "russian-airspace-closure",
      zone_type: :closed_airspace,
      status: :active,
      severity: :critical,
      source_name: "EASA SIB 2022-10",
      source_url: @easa_conflict_zones_url,
      summary_text:
        "Russian airspace closed to all Western and most Asian carriers since February 2022. " <>
          "The single largest structural disruption to Europe–Asia aviation in decades.",
      detail_text:
        "The closure forces every affected airline to reroute via Central Asia, the Gulf, or south of Iran. " <>
          "Pre-closure, a London–Tokyo overflight took ~12 hours. Current routings via Central Asia run " <>
          "14–15 hours, and Gulf alternatives 15–17 hours. The knock-on effect is severe congestion in the " <>
          "Central Asian corridor, which now handles traffic volumes it was not designed for.",
      affected_regions: ["All Europe–Asia corridors", "North Atlantic polar routes"],
      boundary_geojson: %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [28.0, 55.5],
            [40.0, 55.5],
            [60.0, 54.0],
            [80.0, 52.0],
            [100.0, 51.0],
            [120.0, 50.0],
            [140.0, 49.0],
            [160.0, 50.0],
            [180.0, 52.0],
            [180.0, 78.0],
            [120.0, 82.0],
            [40.0, 80.0],
            [28.0, 75.0],
            [28.0, 55.5]
          ]
        ]
      },
      last_updated_at: ~U[2026-03-28 10:00:00Z]
    },
    %{
      name: "Ukraine Conflict Zone",
      slug: "ukraine-conflict-zone",
      zone_type: :conflict,
      status: :active,
      severity: :critical,
      source_name: "EASA SIB 2022-10",
      source_url: @easa_conflict_zones_url,
      summary_text:
        "Active conflict. Ukrainian and Belarusian airspace fully closed to commercial aviation. " <>
          "All carriers avoid this region without exception.",
      detail_text:
        "Full NOTAM closure since February 2022. No commercial aviation transits Ukraine or Belarus. " <>
          "Flights that previously used these corridors to reach Turkey, the Middle East, or further east " <>
          "now route around the southern boundary of the closure, adding modest but consistent time to " <>
          "journeys from central and northern Europe.",
      affected_regions: ["Eastern Europe", "Black Sea approaches"],
      boundary_geojson: %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [22.0, 44.5],
            [24.0, 44.0],
            [30.0, 44.5],
            [34.0, 45.0],
            [40.5, 47.0],
            [40.5, 53.0],
            [32.0, 54.0],
            [24.0, 54.0],
            [22.0, 52.0],
            [22.0, 44.5]
          ]
        ]
      },
      last_updated_at: ~U[2026-03-28 10:00:00Z]
    },
    %{
      name: "Middle East Advisory Zone",
      slug: "middle-east-advisory",
      zone_type: :advisory,
      status: :active,
      severity: :high,
      source_name: "EASA SIB 2020-01",
      source_url: @easa_conflict_zones_url,
      summary_text:
        "Active elevated advisory across the Levant and Gulf approaches. Gulf hub operations continue, " <>
          "but routes through this airspace carry meaningful disruption risk. This zone is materially " <>
          "more pressured than pre-2024 conditions.",
      detail_text:
        "Regional conflict in Gaza and Lebanon, combined with periodic Iranian airspace interventions, " <>
          "has elevated advisory status for the entire zone. Gulf carriers (Emirates, Qatar Airways, Etihad) " <>
          "continue operating but have made routing adjustments. UK FCDO, US State Dept, and EU advisories " <>
          "all flag this region for heightened monitoring. Airlines overflying Iraqi or Iranian airspace to " <>
          "reach the Gulf carry sector-specific risk that is distinct from Gulf hub risk.",
      affected_regions: ["Levant corridor", "Iraqi airspace", "Gulf approaches", "Red Sea"],
      boundary_geojson: %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [34.0, 29.0],
            [37.0, 26.0],
            [45.0, 22.0],
            [58.0, 22.0],
            [60.0, 26.0],
            [58.0, 30.0],
            [55.0, 34.0],
            [48.0, 37.0],
            [40.0, 37.0],
            [36.0, 35.0],
            [34.5, 32.0],
            [34.0, 29.0]
          ]
        ]
      },
      last_updated_at: ~U[2026-03-28 10:00:00Z]
    },
    %{
      name: "Iranian Airspace Advisory",
      slug: "iranian-airspace-advisory",
      zone_type: :advisory,
      status: :monitoring,
      severity: :moderate,
      source_name: "EASA SIB 2020-01",
      source_url: @easa_conflict_zones_url,
      summary_text:
        "Iranian airspace (Tehran FIR) carries elevated advisory status. Most carriers continue " <>
          "overflights with enhanced monitoring, but some Western airlines now route around Iranian FIR entirely.",
      detail_text:
        "Iranian airspace has been used as a tool of regional pressure on multiple occasions, with " <>
          "short-notice NOTAM restrictions and military activity affecting flight planning. Several European " <>
          "carriers have voluntarily suspended Iranian FIR transits. Gulf carriers (operating under different " <>
          "regulatory frameworks) generally continue normal routing. Any traveler on a European-flagged airline " <>
          "transiting Iranian FIR should be aware of elevated disruption probability.",
      affected_regions: ["Tehran FIR", "Iranian Gulf approaches"],
      boundary_geojson: %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [44.0, 25.0],
            [44.0, 39.5],
            [48.0, 40.5],
            [54.0, 40.0],
            [58.0, 38.0],
            [63.5, 37.0],
            [63.5, 25.0],
            [58.0, 22.5],
            [50.0, 22.0],
            [44.0, 25.0]
          ]
        ]
      },
      last_updated_at: ~U[2026-03-26 10:00:00Z]
    },
    %{
      name: "Central Asian Corridor (Congestion)",
      slug: "central-asian-corridor",
      zone_type: :congestion,
      status: :monitoring,
      severity: :moderate,
      source_name: "Eurocontrol CFA",
      source_url: @eurocontrol_cfa_url,
      summary_text:
        "The Central Asian corridor (primarily Kazakh, Uzbek, and Tajik airspace) now handles traffic " <>
          "volumes far above its pre-2022 design capacity. Periodic flow restrictions cause delays and " <>
          "occasional rerouting.",
      detail_text:
        "This narrow corridor — roughly 300–500km wide between closed Russian airspace to the north and " <>
          "Iranian advisory airspace to the south — is the sole viable path for most Europe-to-Asia flights " <>
          "that cannot use Gulf routing. Eurocontrol issues ATFM flow restrictions on this corridor multiple " <>
          "times per week during peak periods. Airlines have reported average delays of 30–60 minutes per " <>
          "disruption event. The corridor is functioning but operating at structural stress.",
      affected_regions: ["Kazakhstan FIR", "Uzbekistan FIR", "Tajikistan FIR"],
      boundary_geojson: %{
        "type" => "Polygon",
        "coordinates" => [
          [
            [50.0, 37.0],
            [55.0, 37.0],
            [65.0, 36.0],
            [75.0, 37.0],
            [80.0, 40.0],
            [80.0, 52.0],
            [70.0, 54.0],
            [58.0, 52.0],
            [50.0, 48.0],
            [48.0, 42.0],
            [50.0, 37.0]
          ]
        ]
      },
      last_updated_at: ~U[2026-03-27 10:00:00Z]
    }
  ]

  @doc "Returns all zone definition maps, suitable for direct use in seeds or tests."
  def all, do: @zones

  @doc "Returns a single zone definition by slug, or nil if not found."
  def get(slug), do: Enum.find(@zones, &(&1.slug == slug))
end
