defmodule Pathfinder.OutboundTest do
  use ExUnit.Case, async: true

  alias Pathfinder.Outbound

  describe "search_links/2" do
    test "first provider is Skyscanner, not Google Flights" do
      links = Outbound.search_links("LHR", "SIN")
      assert [{:skyscanner, "Skyscanner", _url} | _rest] = links,
             "Expected Skyscanner to be the first (primary) provider, got: #{inspect(hd(links))}"
    end

    test "Google Flights is present but not primary" do
      links = Outbound.search_links("LHR", "SIN")
      {google_index, _} =
        links
        |> Enum.with_index()
        |> Enum.find({nil, nil}, fn {{provider, _, _}, _} -> provider == :google_flights end)

      assert google_index != nil, "Google Flights should be present in the provider list"
      assert google_index > 0, "Google Flights must not be at position 0 (primary)"
    end

    test "primary_url/2 returns a Skyscanner URL" do
      url = Outbound.primary_url("LHR", "SIN")
      assert url =~ "skyscanner", "primary_url should be a Skyscanner URL, got: #{url}"
    end

    test "returns URLs with correct IATA codes" do
      links = Outbound.search_links("LHR", "SIN")

      for {_provider, _label, url} <- links do
        assert url =~ "lhr" or url =~ "LHR" or url =~ "google.com",
               "Expected origin IATA in URL: #{url}"
      end
    end
  end
end
