defmodule Pathfinder.Disruption.DisruptionZone do
  use Ecto.Schema
  import Ecto.Changeset

  @zone_types [:conflict, :closed_airspace, :advisory, :congestion]
  @statuses [:active, :monitoring, :resolved]
  @severities [:low, :moderate, :high, :critical]

  schema "disruption_zones" do
    field :name, :string
    field :slug, :string
    field :zone_type, Ecto.Enum, values: @zone_types
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :severity, Ecto.Enum, values: @severities, default: :moderate
    field :summary_text, :string
    field :detail_text, :string
    field :boundary_geojson, :map
    field :affected_regions, {:array, :string}, default: []
    field :source_urls, {:array, :string}, default: []
    field :valid_from, :utc_datetime
    field :valid_until, :utc_datetime
    field :last_updated_at, :utc_datetime

    # Freshness / source tracking (added 2026-04-04)
    field :source_name, :string          # human-readable source name, e.g. "EASA SIB 2022-10"
    field :source_url, :string           # primary URL being monitored for changes
    field :source_revision_date, :date   # revision date parsed from source page (if extractable)
    field :last_checked_at, :utc_datetime  # when we last fetched the source URL
    field :last_changed_at, :utc_datetime  # when we last detected a content change
    field :review_status, :string, default: "current"  # "current" | "review_required"
    field :source_hash, :string          # SHA-256 of monitored page content (for change detection)
    field :consecutive_check_failures, :integer, default: 0  # incremented on each fetch error, reset to 0 on success

    has_many :route_factors, Pathfinder.Routes.RouteDisruptionFactor

    timestamps(type: :utc_datetime)
  end

  def changeset(zone, attrs) do
    zone
    |> cast(attrs, [
      :name, :slug, :zone_type, :status, :severity,
      :summary_text, :detail_text, :boundary_geojson,
      :affected_regions, :source_urls,
      :valid_from, :valid_until, :last_updated_at,
      :source_name, :source_url, :source_revision_date,
      :last_checked_at, :last_changed_at, :review_status, :source_hash,
      :consecutive_check_failures
    ])
    |> validate_required([:name, :slug, :zone_type, :status, :severity, :summary_text])
    |> unique_constraint(:slug)
  end

  def severity_color(:low), do: "#fbbf24"
  def severity_color(:moderate), do: "#fb923c"
  def severity_color(:high), do: "#f87171"
  def severity_color(:critical), do: "#dc2626"

  def severity_opacity(:low), do: 0.10
  def severity_opacity(:moderate), do: 0.15
  def severity_opacity(:high), do: 0.22
  def severity_opacity(:critical), do: 0.30
end
