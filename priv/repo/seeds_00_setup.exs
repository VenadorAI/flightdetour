alias Pathfinder.Repo
alias Pathfinder.Routes.{City, Route, RouteScore}
alias Pathfinder.Disruption.DisruptionZone
alias Pathfinder.Scoring
alias Pathfinder.CitySlug

# ─── CITIES ───────────────────────────────────────────────────────────────────

cities_data = [
  %{name: "London",       country: "United Kingdom", iata_codes: ["LHR","LGW"], lat: 51.477, lng: -0.461},
  %{name: "Frankfurt",    country: "Germany",         iata_codes: ["FRA"],       lat: 50.033, lng: 8.570},
  %{name: "Amsterdam",    country: "Netherlands",     iata_codes: ["AMS"],       lat: 52.308, lng: 4.764},
  %{name: "Paris",        country: "France",          iata_codes: ["CDG","ORY"], lat: 49.010, lng: 2.549},
  %{name: "Istanbul",     country: "Turkey",          iata_codes: ["IST"],       lat: 40.976, lng: 28.816},
  %{name: "Dubai",        country: "UAE",             iata_codes: ["DXB"],       lat: 25.253, lng: 55.364},
  %{name: "Doha",         country: "Qatar",           iata_codes: ["DOH"],       lat: 25.273, lng: 51.608},
  %{name: "Abu Dhabi",    country: "UAE",             iata_codes: ["AUH"],       lat: 24.433, lng: 54.651},
  %{name: "Singapore",    country: "Singapore",       iata_codes: ["SIN"],       lat: 1.359,  lng: 103.989},
  %{name: "Bangkok",      country: "Thailand",        iata_codes: ["BKK"],       lat: 13.681, lng: 100.747},
  %{name: "Hong Kong",    country: "China SAR",       iata_codes: ["HKG"],       lat: 22.309, lng: 113.915},
  %{name: "Tokyo",        country: "Japan",           iata_codes: ["NRT","HND"], lat: 35.765, lng: 140.386},
  %{name: "Kuala Lumpur", country: "Malaysia",        iata_codes: ["KUL"],       lat: 2.743,  lng: 101.710},
  %{name: "Delhi",        country: "India",           iata_codes: ["DEL"],       lat: 28.556, lng: 77.103},
  %{name: "Mumbai",       country: "India",           iata_codes: ["BOM"],       lat: 19.089, lng: 72.868},
  %{name: "Seoul",        country: "South Korea",     iata_codes: ["ICN"],       lat: 37.456, lng: 126.451},
  %{name: "Colombo",      country: "Sri Lanka",       iata_codes: ["CMB"],       lat: 7.180,  lng: 79.884},
  %{name: "Jakarta",      country: "Indonesia",       iata_codes: ["CGK"],       lat: -6.127, lng: 106.656},
  %{name: "Sydney",       country: "Australia",       iata_codes: ["SYD"],       lat: -33.946, lng: 151.177},
  %{name: "Madrid",       country: "Spain",           iata_codes: ["MAD"],       lat: 40.472,  lng: -3.561},
  %{name: "Munich",       country: "Germany",          iata_codes: ["MUC"],       lat: 48.354,  lng: 11.786},
  %{name: "Rome",         country: "Italy",             iata_codes: ["FCO"],       lat: 41.804,  lng: 12.239},
  %{name: "Zurich",       country: "Switzerland",       iata_codes: ["ZRH"],       lat: 47.464,  lng: 8.549},
  %{name: "Beijing",      country: "China",             iata_codes: ["PEK","PKX"], lat: 40.070,  lng: 116.590},
  %{name: "New York",    country: "United States",     iata_codes: ["JFK","EWR"], lat: 40.641,  lng: -73.778},
  %{name: "Los Angeles", country: "United States",     iata_codes: ["LAX"],       lat: 33.943,  lng: -118.408},
  %{name: "Toronto",     country: "Canada",            iata_codes: ["YYZ"],       lat: 43.677,  lng: -79.631},
  %{name: "Vancouver",   country: "Canada",            iata_codes: ["YVR"],       lat: 49.195,  lng: -123.184},
  %{name: "Shanghai",    country: "China",             iata_codes: ["PVG","SHA"], lat: 31.143,  lng: 121.805},
]

cities =
  Enum.reduce(cities_data, %{}, fn attrs, acc ->
    attrs = Map.put(attrs, :slug, CitySlug.from_name(attrs.name))
    city =
      case Repo.get_by(City, name: attrs.name) do
        nil      -> Repo.insert!(City.changeset(%City{}, attrs))
        existing -> Repo.update!(City.changeset(existing, attrs))
      end
    Map.put(acc, attrs.name, city)
  end)

IO.puts("✓ #{map_size(cities)} cities")

# ─── DISRUPTION ZONES ─────────────────────────────────────────────────────────
# Zone definitions live in lib/pathfinder/disruption/zone_definitions.ex.
# To update advisory status, severity, or copy, edit that file and re-run seeds.

zones =
  Enum.reduce(Pathfinder.Disruption.ZoneDefinitions.all(), %{}, fn attrs, acc ->
    zone =
      case Repo.get_by(DisruptionZone, slug: attrs.slug) do
        nil      -> Repo.insert!(DisruptionZone.changeset(%DisruptionZone{}, attrs))
        existing -> Repo.update!(DisruptionZone.changeset(existing, attrs))
      end
    Map.put(acc, attrs.slug, zone)
  end)

IO.puts("✓ #{map_size(zones)} disruption zones")

# ─── ROUTE CLEANUP ───────────────────────────────────────────────────────────
# Deactivate all routes before re-seeding so stale routes from previous runs
# (e.g. renamed routes) don't appear in results. Each upsert below re-enables
# the routes it owns via is_active: true.

import Ecto.Query
{deactivated, _} = Repo.update_all(Route, set: [is_active: false])
IO.puts("  ↺ deactivated #{deactivated} stale routes")
