defmodule Pathfinder.Outbound do
  @moduledoc """
  Configurable outbound link generation for flight search handoff.

  ## Configuration

  Provider list and order is set via application config:

      config :pathfinder, Pathfinder.Outbound,
        providers: [:google_flights, :skyscanner]

  Supported provider keys: :google_flights, :skyscanner
  First provider in the list is the primary CTA shown in result cards.

  ## Adding a new provider

  1. Add a `build/3` clause below following the existing pattern.
  2. Add the provider atom to the config list.
  3. Templates call `search_links/2` — no template edits needed.

  ## Activating affiliate params

  Set the relevant env var (see each clause below). All templates and
  the /go redirect controller pick up the change automatically.
  """

  @default_providers [:skyscanner, :google_flights]

  @doc """
  Returns `[{provider_atom, display_label, url}]` for all configured providers.
  Primary provider (first in list) is always first.
  Unknown or unconfigured provider atoms are silently dropped.
  """
  def search_links(iata_origin, iata_dest) do
    providers()
    |> Enum.map(&build(&1, iata_origin, iata_dest))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns the destination URL for a specific provider and IATA pair.
  Used by GoController to build the redirect target after logging the click.
  Returns nil for unknown providers.
  """
  def url_for(provider, iata_origin, iata_dest) do
    case build(provider, iata_origin, iata_dest) do
      {_provider_atom, _label, url} -> url
      nil -> nil
    end
  end

  @doc """
  Primary CTA URL — first configured provider.
  Returns nil if no providers are configured.
  """
  def primary_url(iata_origin, iata_dest) do
    case search_links(iata_origin, iata_dest) do
      [{_provider, _label, url} | _] -> url
      [] -> nil
    end
  end

  @doc "Generic CTA label for buttons that don't have pair context."
  def primary_label, do: "Search flights"

  @doc """
  Pair-specific CTA label, e.g. "Search LHR → SIN".
  Falls back to primary_label/0 if IATA codes are blank.
  """
  def search_route_label(iata_origin, iata_dest)
      when is_binary(iata_origin) and iata_origin != ""
      and is_binary(iata_dest) and iata_dest != "" do
    "Search #{iata_origin} → #{iata_dest}"
  end

  def search_route_label(_o, _d), do: primary_label()

  # ── Provider configuration ──────────────────────────────────────────────────

  defp providers do
    Application.get_env(:pathfinder, __MODULE__, [])
    |> Keyword.get(:providers, @default_providers)
  end

  # ── Provider URL builders ────────────────────────────────────────────────────
  #
  # Each clause returns {provider_atom, display_label, url} or nil.
  # provider_atom is used by GoController to reconstruct the URL after logging.

  defp build(:google_flights, a, b) do
    # Google Flights — no affiliate program. UTM params track contribution.
    # Deep-link format: google.com/flights#flt=ORIGIN.DEST. (trailing dot required)
    url = "https://www.google.com/flights?utm_source=flightdetour&utm_medium=outbound#flt=#{a}.#{b}."
    {:google_flights, "Google Flights", url}
  end

  defp build(:skyscanner, a, b) do
    # Skyscanner — affiliate-ready. Set SKYSCANNER_ASSOCIATE_ID in production
    # to attribute traffic and earn commission via the Skyscanner Partner Programme.
    # Sign up at: https://www.partners.skyscanner.net
    base = "https://www.skyscanner.net/transport/flights/#{String.downcase(a)}/#{String.downcase(b)}/"
    associate_id = System.get_env("SKYSCANNER_ASSOCIATE_ID", "")

    url =
      if associate_id != "" do
        base <> "?associateid=#{associate_id}&utm_source=flightdetour&utm_medium=outbound"
      else
        base <> "?utm_source=flightdetour&utm_medium=outbound"
      end

    {:skyscanner, "Skyscanner", url}
  end

  defp build(_unknown, _a, _b), do: nil
end
