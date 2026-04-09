defmodule Pathfinder.Routes.City do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cities" do
    field :name, :string
    field :slug, :string
    field :country, :string
    field :iata_codes, {:array, :string}, default: []
    field :lat, :float
    field :lng, :float
    field :is_active, :boolean, default: true

    has_many :origin_routes, Pathfinder.Routes.Route, foreign_key: :origin_city_id
    has_many :destination_routes, Pathfinder.Routes.Route, foreign_key: :destination_city_id

    timestamps(type: :utc_datetime)
  end

  def changeset(city, attrs) do
    city
    |> cast(attrs, [:name, :slug, :country, :iata_codes, :lat, :lng, :is_active])
    |> validate_required([:name, :country, :lat, :lng])
    |> unique_constraint(:slug)
  end
end
