defmodule Pathfinder.Routes.RouteDisruptionFactor do
  use Ecto.Schema
  import Ecto.Changeset

  @factor_types [
    :airspace_exposure,
    :corridor_dependency,
    :hub_risk,
    :complexity,
    :operational
  ]

  schema "route_disruption_factors" do
    belongs_to :route, Pathfinder.Routes.Route
    belongs_to :disruption_zone, Pathfinder.Disruption.DisruptionZone

    field :factor_type, Ecto.Enum, values: @factor_types
    field :factor_score, :integer
    field :explanation_text, :string
    field :assessed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(factor, attrs) do
    factor
    |> cast(attrs, [:route_id, :disruption_zone_id, :factor_type, :factor_score, :explanation_text, :assessed_at])
    |> validate_required([:route_id, :factor_type, :factor_score, :explanation_text, :assessed_at])
    |> validate_number(:factor_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
  end
end
