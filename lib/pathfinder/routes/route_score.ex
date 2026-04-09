defmodule Pathfinder.Routes.RouteScore do
  use Ecto.Schema
  import Ecto.Changeset

  @labels [:flowing, :watchful, :constrained, :strained]

  schema "route_scores" do
    belongs_to :route, Pathfinder.Routes.Route

    # Factor inputs (0–3, higher = worse)
    field :airspace_score,    :integer, default: 0
    field :corridor_score,    :integer, default: 0
    field :hub_score,         :integer, default: 0
    field :complexity_score,  :integer, default: 0
    field :operational_score, :integer, default: 0

    # Layer scores (0–100, higher = better)
    field :structural_score, :integer
    field :pressure_score,   :integer

    # Composite + label
    field :composite_score, :integer
    field :label, Ecto.Enum, values: @labels

    # Advisory fields
    field :recommendation_text, :string
    field :ranking_context,     :string
    field :watch_for,           :string
    field :explanation_bullets, {:array, :string}, default: []
    field :score_cap_reason,    :string

    field :calculated_at, :utc_datetime

    # Freshness tracking (added 2026-04-04)
    # "current" | "aging" | "stale" | "review_required"
    field :freshness_state, :string, default: "current"

    timestamps(type: :utc_datetime)
  end

  def changeset(score, attrs) do
    score
    |> cast(attrs, [
      :route_id,
      :airspace_score, :corridor_score, :hub_score,
      :complexity_score, :operational_score,
      :structural_score, :pressure_score,
      :composite_score, :label,
      :recommendation_text, :ranking_context, :watch_for,
      :explanation_bullets, :score_cap_reason,
      :calculated_at,
      :freshness_state
    ])
    |> validate_required([:route_id, :composite_score, :label, :calculated_at])
    |> validate_inclusion(:label, @labels)
    |> validate_number(:composite_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  # --- UI helpers ---

  def label_color(:flowing),     do: "text-emerald-400"
  def label_color(:watchful),    do: "text-amber-400"
  def label_color(:constrained), do: "text-orange-400"
  def label_color(:strained),    do: "text-red-400"

  def label_bg(:flowing),     do: "bg-emerald-400/10 border-emerald-400/30"
  def label_bg(:watchful),    do: "bg-amber-400/10 border-amber-400/30"
  def label_bg(:constrained), do: "bg-orange-400/10 border-orange-400/30"
  def label_bg(:strained),    do: "bg-red-400/10 border-red-400/30"

  def label_dot(:flowing),     do: "bg-emerald-400"
  def label_dot(:watchful),    do: "bg-amber-400"
  def label_dot(:constrained), do: "bg-orange-400"
  def label_dot(:strained),    do: "bg-red-400"

  def layer_color(:flowing),     do: "#34d399"
  def layer_color(:watchful),    do: "#fbbf24"
  def layer_color(:constrained), do: "#fb923c"
  def layer_color(:strained),    do: "#f87171"

  def map_color(:flowing),     do: "#34d399"
  def map_color(:watchful),    do: "#fbbf24"
  def map_color(:constrained), do: "#fb923c"
  def map_color(:strained),    do: "#f87171"

  def label_text(label), do: label |> Atom.to_string() |> String.capitalize()

  # Label for a raw layer score (structural or pressure)
  def layer_label(score) when score >= 75, do: "Strong"
  def layer_label(score) when score >= 56, do: "Moderate"
  def layer_label(score) when score >= 38, do: "Constrained"
  def layer_label(_),                      do: "Strained"

  def layer_label_color(score) when score >= 75, do: "text-emerald-400"
  def layer_label_color(score) when score >= 56, do: "text-amber-400"
  def layer_label_color(score) when score >= 38, do: "text-orange-400"
  def layer_label_color(_),                      do: "text-red-400"
end
