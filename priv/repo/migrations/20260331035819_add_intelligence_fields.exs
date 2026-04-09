defmodule Pathfinder.Repo.Migrations.AddIntelligenceFields do
  use Ecto.Migration

  def change do
    alter table(:routes) do
      add :corridor_family, :string
    end

    alter table(:route_scores) do
      add :structural_score, :integer
      add :pressure_score, :integer
      add :score_cap_reason, :string
      add :ranking_context, :text
      add :watch_for, :string
    end

    create index(:routes, [:corridor_family])
  end
end
