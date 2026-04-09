defmodule Pathfinder.Repo.Migrations.AddFreshnessFields do
  use Ecto.Migration

  def change do
    # Per-zone source tracking + change detection
    alter table(:disruption_zones) do
      add :source_name, :string
      add :source_url, :string
      add :source_revision_date, :date
      add :last_checked_at, :utc_datetime
      add :last_changed_at, :utc_datetime
      add :review_status, :string, default: "current"
      add :source_hash, :string
    end

    # Per-route freshness classification
    alter table(:route_scores) do
      add :freshness_state, :string, default: "current"
    end
  end
end
