defmodule Pathfinder.Advisory.FreshnessTest do
  use ExUnit.Case, async: true

  alias Pathfinder.Advisory.Freshness

  # ──────────────────────────────────────────────────────────────────────────────
  # compute/2 — state transitions
  # ──────────────────────────────────────────────────────────────────────────────

  describe "compute/2 — state transitions" do
    test "current: reviewed within 7 days, no zone changes" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      assert Freshness.compute(reviewed_at, []) == :current
    end

    test "current: reviewed today" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert Freshness.compute(reviewed_at, []) == :current
    end

    test "aging: reviewed 8–30 days ago, no zone changes" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)
      assert Freshness.compute(reviewed_at, []) == :aging
    end

    test "stale: not reviewed for more than 30 days" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -35 * 86_400, :second)
      assert Freshness.compute(reviewed_at, []) == :stale
    end

    test "stale: nil last_reviewed_at" do
      assert Freshness.compute(nil, []) == :stale
    end

    test "review_required: a zone changed AFTER the last review" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      zone_changed = DateTime.add(DateTime.utc_now(), -86_400, :second)
      zone = %{last_changed_at: zone_changed}

      assert Freshness.compute(reviewed_at, [zone]) == :review_required
    end

    test "not review_required: zone change BEFORE the last review" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      zone_changed = DateTime.add(DateTime.utc_now(), -5 * 86_400, :second)
      zone = %{last_changed_at: zone_changed}

      # Zone change predates review — should compute as :current
      assert Freshness.compute(reviewed_at, [zone]) == :current
    end

    test "review_required takes priority over stale" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      zone_changed = DateTime.add(DateTime.utc_now(), -86_400, :second)
      zone = %{last_changed_at: zone_changed}

      assert Freshness.compute(reviewed_at, [zone]) == :review_required
    end

    test "zones with nil last_changed_at are ignored" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
      zone = %{last_changed_at: nil}

      assert Freshness.compute(reviewed_at, [zone]) == :current
    end

    test "review_required when any zone changed, even if others didn't" do
      reviewed_at = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      clean_zone = %{last_changed_at: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)}
      changed_zone = %{last_changed_at: DateTime.add(DateTime.utc_now(), -86_400, :second)}

      assert Freshness.compute(reviewed_at, [clean_zone, changed_zone]) == :review_required
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # source_context/2 — reassurance string
  # ──────────────────────────────────────────────────────────────────────────────

  describe "source_context/2" do
    test "returns reassurance for :aging + recent source check (< 24h)" do
      checked_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Freshness.source_context(:aging, checked_at)
      assert is_binary(result)
      assert result =~ "Sources verified"
      assert result =~ "no advisory changes"
    end

    test "returns reassurance for :stale + recent source check" do
      checked_at = DateTime.add(DateTime.utc_now(), -1800, :second)
      result = Freshness.source_context(:stale, checked_at)
      assert is_binary(result)
      assert result =~ "Sources verified"
    end

    test "returns nil for :current (no reassurance needed)" do
      checked_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert Freshness.source_context(:current, checked_at) == nil
    end

    test "returns nil for :review_required (source change detected — no false reassurance)" do
      checked_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert Freshness.source_context(:review_required, checked_at) == nil
    end

    test "returns nil when checked_at is nil" do
      assert Freshness.source_context(:aging, nil) == nil
    end

    test "returns nil when source check is stale (> 24h)" do
      checked_at = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      assert Freshness.source_context(:aging, checked_at) == nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # format_age/1 — human-readable age labels
  # ──────────────────────────────────────────────────────────────────────────────

  describe "format_age/1" do
    test "shows minutes for recent datetimes" do
      dt = DateTime.add(DateTime.utc_now(), -300, :second)
      assert Freshness.format_age(dt) == "5m ago"
    end

    test "rounds up to 1 minute for very recent (<60s)" do
      dt = DateTime.add(DateTime.utc_now(), -30, :second)
      assert Freshness.format_age(dt) == "1m ago"
    end

    test "shows hours for same-day datetimes" do
      dt = DateTime.add(DateTime.utc_now(), -7200, :second)
      assert Freshness.format_age(dt) == "2h ago"
    end

    test "shows days for older datetimes" do
      dt = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      assert Freshness.format_age(dt) == "3d ago"
    end

    test "returns nil for nil" do
      assert Freshness.format_age(nil) == nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # label/1 and chip_class/1 — UI helpers completeness
  # ──────────────────────────────────────────────────────────────────────────────

  describe "label/1" do
    test "returns nil for :current (chip is hidden)" do
      assert Freshness.label(:current) == nil
    end

    test "returns non-nil label for all non-current states" do
      for state <- [:aging, :stale, :review_required] do
        assert is_binary(Freshness.label(state)), "Expected string label for #{state}"
      end
    end
  end

  describe "chip_class/1" do
    test "returns empty string for :current" do
      assert Freshness.chip_class(:current) == ""
    end

    test "returns non-empty class for all non-current states" do
      for state <- [:aging, :stale, :review_required] do
        assert Freshness.chip_class(state) != "", "Expected non-empty chip class for #{state}"
      end
    end
  end
end
