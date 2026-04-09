defmodule Pathfinder.Advisory.Freshness do
  @moduledoc """
  Freshness classification for route advisory data.

  A route's freshness is a function of two independent signals:
    1. Age — how many days since the route copy was last reviewed by a human
    2. Source drift — whether an upstream advisory source changed after the route was reviewed

  States (in descending priority):
    :review_required — a source zone changed after the route was last reviewed
    :stale           — not reviewed in over 30 days (and no zone change detected)
    :aging           — reviewed 7–30 days ago (and no zone change detected)
    :current         — reviewed within 7 days, no zone changes since review

  The stored `freshness_state` in route_scores is authoritative for query/admin.
  Use `compute/2` when you have live zone data to evaluate at render time.
  """

  @current_days 7
  @stale_days 30

  @doc """
  Compute freshness from a last_reviewed_at datetime and a list of affecting zones.
  Zones must have a `last_changed_at` field.
  """
  def compute(last_reviewed_at, zones_affecting \\ []) do
    cond do
      review_required?(last_reviewed_at, zones_affecting) -> :review_required
      stale?(last_reviewed_at) -> :stale
      aging?(last_reviewed_at) -> :aging
      true -> :current
    end
  end

  @doc "Parse stored string freshness_state to atom."
  def from_string(nil), do: :current
  def from_string(s), do: String.to_atom(s)

  @doc "Return freshness atom from a route score struct."
  def for_score(%{freshness_state: s}), do: from_string(s)
  def for_score(_), do: :current

  # --- Classification ---

  defp review_required?(_reviewed_at, []), do: false
  defp review_required?(nil, _zones), do: false

  defp review_required?(reviewed_at, zones) do
    Enum.any?(zones, fn zone ->
      not is_nil(zone.last_changed_at) and
        DateTime.compare(zone.last_changed_at, reviewed_at) == :gt
    end)
  end

  defp stale?(nil), do: true
  defp stale?(reviewed_at), do: days_ago(reviewed_at) > @stale_days

  defp aging?(nil), do: true
  defp aging?(reviewed_at), do: days_ago(reviewed_at) > @current_days

  defp days_ago(dt), do: DateTime.diff(DateTime.utc_now(), dt, :day)

  # --- UI helpers ---

  @doc "Short label shown in UI chips. Returns nil for :current (chip is hidden)."
  def label(:current), do: nil
  def label(:aging), do: "Aging"
  def label(:stale), do: "Stale"
  def label(:review_required), do: "Advisory changed"

  @doc "Tailwind classes for the freshness chip."
  def chip_class(:current), do: ""
  def chip_class(:aging), do: "text-amber-400/70 border-amber-400/20 bg-amber-400/5"
  def chip_class(:stale), do: "text-orange-400/70 border-orange-400/25 bg-orange-400/5"
  def chip_class(:review_required), do: "text-red-400/70 border-red-400/25 bg-red-400/5"

  @doc "Human-readable description of the freshness state for the detail page."
  def description(:current), do: "Assessment is current."
  def description(:aging), do: "This score is 8–30 days old. If you're booking soon, check for recent advisories."
  def description(:stale), do: "Score is over 30 days old. Check your airline and government advisories before booking."
  def description(:review_required), do: "An advisory source changed after this route was last assessed. The score may not reflect current conditions — verify before booking."

  @doc "Tailwind color class for the freshness description line."
  def description_color(:current), do: "text-emerald-400/60"
  def description_color(:aging), do: "text-amber-400/60"
  def description_color(:stale), do: "text-orange-400/70"
  def description_color(:review_required), do: "text-red-400/70"

  @doc """
  Human-readable label for when data was last checked.
  Accepts a DateTime directly (e.g. route.last_reviewed_at or latest_source_check).
  Returns nil when reviewed_at is nil.

  Examples: "Checked today", "Checked yesterday", "Checked 4 days ago"
  """
  def relative_review_date(nil), do: nil

  def relative_review_date(%DateTime{} = reviewed_at) do
    days = days_ago(reviewed_at)

    cond do
      days < 1 -> "Checked today"
      days < 2 -> "Checked yesterday"
      true -> "Checked #{days} days ago"
    end
  end

  @doc """
  Sub-day-aware age label. Returns "Xm ago", "Xh ago", or "Xd ago".
  Use this when recency within a day matters (e.g. source check timestamps).
  """
  def format_age(nil), do: nil

  def format_age(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      secs < 3_600 ->
        mins = max(div(secs, 60), 1)
        "#{mins}m ago"

      secs < 86_400 ->
        hours = div(secs, 3_600)
        "#{hours}h ago"

      true ->
        days = div(secs, 86_400)
        "#{days}d ago"
    end
  end

  @doc """
  "Advisory sources checked 3h ago" — for zone last_checked_at timestamps.
  Returns nil when checked_at is nil.
  """
  def source_check_label(nil), do: nil

  def source_check_label(%DateTime{} = checked_at) do
    "Advisory sources checked #{format_age(checked_at)}"
  end

  @doc """
  "Route last assessed 2d ago" — for route last_reviewed_at timestamps.
  Returns nil when reviewed_at is nil.
  """
  def route_review_label(nil), do: nil

  def route_review_label(%DateTime{} = reviewed_at) do
    "Route last assessed #{format_age(reviewed_at)}"
  end

  @doc """
  Returns a reassurance string when a route's freshness state is :aging or :stale
  but the advisory sources have been checked recently (within 24 hours) with no changes.

  This is the key UX distinction: a route can be :aging (reviewed 8–30 days ago)
  but still trustworthy if automated source checks confirm no advisory changes since.

  Returns nil when the state is :current, :review_required, or when the last check is
  stale (> 24 hours) — in those cases the existing chip/label is sufficient.
  """
  def source_context(state, last_checked_at)

  def source_context(:current, _), do: nil
  def source_context(:review_required, _), do: nil
  def source_context(_, nil), do: nil

  def source_context(state, %DateTime{} = checked_at) when state in [:aging, :stale] do
    hours = DateTime.diff(DateTime.utc_now(), checked_at, :second) |> div(3600)

    if hours < 24 do
      case state do
        :aging ->
          "Advisory sources checked #{format_age(checked_at)} — no changes found. Score is current."

        :stale ->
          "Advisory sources checked #{format_age(checked_at)} — no source changes found. Route copy is over 30 days old; verify with your airline before booking."
      end
    else
      nil
    end
  end

  def source_context(_, _), do: nil
end
