defmodule Pathfinder.CitySlug do
  @moduledoc """
  Deterministic, reversible slug generation for city names and city pairs.

  Rules:
    - Lowercase, non-alphanumeric runs become single hyphens
    - Leading/trailing hyphens stripped
    - Pair slugs use "-to-" as separator: "london-to-singapore"

  The "-to-" separator is safe for all current city names — no city slug
  contains the literal sequence "-to-" within it.
  """

  @doc "Generate a URL-safe slug from a city name. 'Hong Kong' → 'hong-kong'."
  def from_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc "Generate a canonical pair slug. ('London', 'Singapore') → 'london-to-singapore'."
  def pair_slug(origin_name, destination_name) do
    "#{from_name(origin_name)}-to-#{from_name(destination_name)}"
  end

  @doc """
  Split a pair slug into {origin_slug, destination_slug}.
  Returns {:ok, origin, dest} or :error.
  """
  def parse_pair_slug(pair_slug) do
    case String.split(pair_slug, "-to-", parts: 2) do
      [origin, dest] when origin != "" and dest != "" -> {:ok, origin, dest}
      _ -> :error
    end
  end
end
