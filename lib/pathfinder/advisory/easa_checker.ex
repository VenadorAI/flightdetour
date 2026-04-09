defmodule Pathfinder.Advisory.EASAChecker do
  @moduledoc """
  Monitors official advisory sources for changes to conflict-zone data.

  ## How it works

  Each disruption zone has a `source_url` field pointing to its primary
  monitoring page (e.g. the EASA conflict zones SIB index). The checker:

    1. Loads all zones that have a `source_url`
    2. Groups them by URL so each unique source is fetched once
    3. Fetches the page and computes a SHA-256 hash of the main content
    4. Compares against the stored `source_hash`
    5. If the hash changed: updates `last_changed_at`, `review_status`, and `source_hash`
    6. Always updates `last_checked_at`
    7. Flags affected route scores as "review_required"

  ## Change detection

  Content hashing is deliberately coarse — the entire `<main>` element
  (or full body if absent) is hashed. This means minor page redesigns may
  trigger a false positive. False positives are acceptable: a human then
  confirms whether the advisory data actually changed and marks the route
  as reviewed. False negatives (missed changes) are not acceptable.

  ## Adding new sources

  Set `source_name` and `source_url` on a disruption zone via seeds or the
  admin interface. The checker will pick it up on the next scheduled run.
  No code changes required.
  """

  require Logger
  import Ecto.Query

  alias Pathfinder.Repo
  alias Pathfinder.Disruption.DisruptionZone
  alias Pathfinder.Routes.{RouteDisruptionFactor, RouteScore}

  @fetch_timeout_ms 20_000
  @user_agent "Pathfinder/1.0 Advisory Monitor (+https://github.com/pathfinder-app)"

  @doc """
  Check all zones that have a source_url. Returns `{:ok, summary}` where
  summary is a list of per-source results.
  """
  def check_all do
    zones_with_source =
      Repo.all(from z in DisruptionZone, where: not is_nil(z.source_url))

    if Enum.empty?(zones_with_source) do
      Logger.info("[EASAChecker] No zones have source_url configured — skipping")
      {:ok, []}
    else
      zones_with_source
      |> Enum.group_by(& &1.source_url)
      |> Enum.map(fn {url, zones} -> check_source(url, zones) end)
      |> then(&{:ok, &1})
    end
  end

  # --- Private ---

  defp check_source(url, zones) do
    Logger.info("[EASAChecker] Checking #{url} (#{length(zones)} zone(s))")

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    zone_slugs = Enum.map(zones, & &1.slug)

    case fetch_url(url) do
      {:ok, body} ->
        new_hash = hash_content(body)
        existing_hash = hd(zones).source_hash
        changed = not is_nil(existing_hash) and existing_hash != new_hash
        first_run = is_nil(existing_hash)

        base_attrs = %{last_checked_at: now}

        update_attrs =
          if changed do
            Logger.info("[EASAChecker] Change detected at #{url} — flagging #{length(zones)} zone(s)")
            revision = extract_revision_date(body)
            base_attrs
            |> Map.put(:last_changed_at, now)
            |> Map.put(:review_status, "review_required")
            |> Map.put(:source_hash, new_hash)
            |> then(fn a -> if revision, do: Map.put(a, :source_revision_date, revision), else: a end)
          else
            # First run: store hash but don't flag as changed
            if first_run, do: Map.put(base_attrs, :source_hash, new_hash), else: base_attrs
          end

        # Reset consecutive failure counter on successful fetch
        update_attrs = Map.put(update_attrs, :consecutive_check_failures, 0)

        Repo.update_all(
          from(z in DisruptionZone, where: z.slug in ^zone_slugs),
          set: Map.to_list(update_attrs)
        )

        if changed, do: flag_routes_for_review(zone_slugs)

        %{
          url: url,
          zones: zone_slugs,
          changed: changed,
          first_run: first_run,
          error: false
        }

      {:error, reason} ->
        Logger.warning("[EASAChecker] Failed to fetch #{url}: #{inspect(reason)}")

        # Increment consecutive failure counter — allows admin to detect silent check failure
        {failures_after, _} =
          Repo.update_all(
            from(z in DisruptionZone, where: z.slug in ^zone_slugs),
            inc: [consecutive_check_failures: 1],
            returning: [:consecutive_check_failures]
          )

        max_failures = Enum.reduce(0, failures_after, fn f, acc -> max(f, acc) end)

        if max_failures >= 3 do
          Logger.error(
            "[EASAChecker] #{url} has failed #{max_failures} consecutive check(s). " <>
              "Source monitoring degraded — check network access or source URL. " <>
              "Affected zone(s): #{Enum.join(zone_slugs, ", ")}"
          )
        end

        %{url: url, zones: zone_slugs, changed: false, first_run: false, error: true, reason: reason,
          consecutive_failures: max_failures}
    end
  end

  defp flag_routes_for_review(zone_slugs) do
    zone_ids =
      Repo.all(from z in DisruptionZone, where: z.slug in ^zone_slugs, select: z.id)

    route_ids =
      Repo.all(
        from f in RouteDisruptionFactor,
          where: f.disruption_zone_id in ^zone_ids,
          select: f.route_id,
          distinct: true
      )

    if length(route_ids) > 0 do
      {count, _} =
        Repo.update_all(
          from(s in RouteScore, where: s.route_id in ^route_ids),
          set: [freshness_state: "review_required"]
        )

      Logger.info("[EASAChecker] Marked #{count} route score(s) as review_required")
    end
  end

  defp fetch_url(url) do
    :inets.start()
    :ssl.start()

    url_charlist = String.to_charlist(url)

    http_opts = [
      timeout: @fetch_timeout_ms,
      connect_timeout: 10_000,
      ssl: ssl_opts()
    ]

    headers = [
      {~c"User-Agent", String.to_charlist(@user_agent)},
      {~c"Accept", ~c"text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"},
      {~c"Accept-Language", ~c"en"}
    ]

    case :httpc.request(:get, {url_charlist, headers}, http_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_, status, reason}, _, _}} ->
        {:error, {:http_error, status, to_string(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_opts do
    try do
      # OTP 25+ — use system CA bundle
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    rescue
      _ ->
        # Fallback for older OTP
        [verify: :verify_none]
    end
  end

  # Hash only the <main> element to avoid false positives from nav/cookie banners
  defp hash_content(body) do
    content =
      case Regex.run(~r/<main[^>]*>(.*?)<\/main>/si, body) do
        [_, main_content] -> main_content
        _ -> body
      end

    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  # Try to extract a revision date from EASA-style HTML pages.
  # EASA pages often contain "Last updated: 12 March 2025" or similar.
  defp extract_revision_date(body) do
    patterns = [
      ~r/(?:Last\s+updated?|Updated?|Revised?)[:\s]+(\d{1,2}\s+\w+\s+\d{4})/i,
      ~r/Revision\s+\d+\s*[–\-]\s*(\d{1,2}\s+\w+\s+\d{4})/i
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, body) do
        [_, date_str] -> parse_english_date(date_str)
        _ -> nil
      end
    end)
  end

  @months %{
    "january" => 1, "february" => 2, "march" => 3, "april" => 4,
    "may" => 5, "june" => 6, "july" => 7, "august" => 8,
    "september" => 9, "october" => 10, "november" => 11, "december" => 12,
    "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4,
    "jun" => 6, "jul" => 7, "aug" => 8, "sep" => 9,
    "oct" => 10, "nov" => 11, "dec" => 12
  }

  defp parse_english_date(str) do
    case Regex.run(~r/(\d{1,2})\s+(\w+)\s+(\d{4})/, String.downcase(str)) do
      [_, day, month_str, year] ->
        case Map.get(@months, month_str) do
          nil -> nil
          month ->
            case Date.new(String.to_integer(year), month, String.to_integer(day)) do
              {:ok, date} -> date
              _ -> nil
            end
        end

      _ ->
        nil
    end
  end
end
