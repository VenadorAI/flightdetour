defmodule Pathfinder.Analytics.SearchEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "search_events" do
    field :event_name, :string
    field :origin, :string
    field :destination, :string
    field :pair_slug, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_name, :origin, :destination, :pair_slug, :metadata])
    |> validate_required([:event_name])
  end
end
