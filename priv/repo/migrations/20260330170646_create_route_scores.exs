defmodule Pathfinder.Repo.Migrations.CreateRouteScores do
  use Ecto.Migration

  def change do
    create table(:route_scores) do
      add :route_id, references(:routes, on_delete: :delete_all), null: false
      add :airspace_score, :integer, null: false, default: 0
      add :corridor_score, :integer, null: false, default: 0
      add :hub_score, :integer, null: false, default: 0
      add :complexity_score, :integer, null: false, default: 0
      add :operational_score, :integer, null: false, default: 0
      add :composite_score, :integer, null: false
      # :flowing | :watchful | :constrained | :strained
      add :label, :string, null: false
      add :recommendation_text, :text
      # Human-readable explanation bullets as JSON array
      add :explanation_bullets, {:array, :string}, default: []
      add :calculated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:route_scores, [:route_id])
    create index(:route_scores, [:composite_score])
    create index(:route_scores, [:label])
  end
end
