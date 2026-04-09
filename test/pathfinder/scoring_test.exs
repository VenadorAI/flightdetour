defmodule Pathfinder.ScoringTest do
  use ExUnit.Case, async: true

  alias Pathfinder.Scoring

  # ──────────────────────────────────────────────────────────────────────────────
  # calculate/5 — advisory zone cap (airspace = 2)
  # ──────────────────────────────────────────────────────────────────────────────

  describe "advisory zone cap (airspace = 2)" do
    test "caps composite at 65 when structural factors would push it above 65" do
      # Best possible structural inputs with airspace=2:
      # structural=100, pressure=53 → raw composite=77 → capped at 65
      result = Scoring.calculate(2, 0, 0, 0, 0)

      assert result.composite_score == 65
      assert result.label == :watchful
    end

    test "sets score_cap_reason when cap is triggered" do
      result = Scoring.calculate(2, 0, 0, 0, 0)

      assert result.score_cap_reason != nil
      assert String.contains?(result.score_cap_reason, "65")
    end

    test "does not cap when raw composite is already at or below 65" do
      # Worst structural + advisory airspace: raw composite well below 65, no cap needed
      result = Scoring.calculate(2, 3, 3, 3, 3)

      assert result.composite_score < 65
      assert result.score_cap_reason == nil
    end

    test "advisory zone routes cannot reach the :flowing label (>= 75)" do
      # Best possible case with airspace=2 is composite=65 (:watchful)
      result = Scoring.calculate(2, 0, 0, 0, 0)

      refute result.label == :flowing
      assert result.composite_score <= 65
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # calculate/5 — conflict zone (airspace = 3)
  # ──────────────────────────────────────────────────────────────────────────────

  describe "conflict zone hard cap (airspace = 3)" do
    test "caps pressure_score at 25 even with optimal operational inputs" do
      # Best structural + airspace=3: pressure would be 30 without cap, capped at 25
      result = Scoring.calculate(3, 0, 0, 0, 0)

      assert result.pressure_score == 25
    end

    test "pressure_score cannot exceed 25 regardless of operational score" do
      # Even with best operational, pressure is capped
      result_best_ops = Scoring.calculate(3, 0, 0, 0, 0)
      result_worst_ops = Scoring.calculate(3, 0, 0, 0, 3)

      assert result_best_ops.pressure_score <= 25
      assert result_worst_ops.pressure_score <= 25
    end

    test "sets score_cap_reason for conflict zone routes" do
      result = Scoring.calculate(3, 0, 0, 0, 0)

      assert result.score_cap_reason != nil
      assert String.contains?(result.score_cap_reason, "conflict")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # calculate/5 — clean routes
  # ──────────────────────────────────────────────────────────────────────────────

  describe "clean routes (airspace = 0)" do
    test "can reach :flowing label with optimal inputs" do
      result = Scoring.calculate(0, 0, 0, 0, 0)

      assert result.composite_score == 100
      assert result.label == :flowing
    end

    test "does not set score_cap_reason" do
      result = Scoring.calculate(0, 0, 0, 0, 0)

      assert result.score_cap_reason == nil
    end

    test "composite is not artificially constrained" do
      result = Scoring.calculate(0, 1, 1, 0, 0)

      assert result.composite_score > 65
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # label_for/1 — boundary conditions
  # ──────────────────────────────────────────────────────────────────────────────

  describe "label_for/1 boundaries" do
    test ":flowing starts at 72" do
      assert Scoring.label_for(72) == :flowing
      assert Scoring.label_for(75) == :flowing
      assert Scoring.label_for(100) == :flowing
    end

    test ":watchful is 56–71" do
      assert Scoring.label_for(71) == :watchful
      assert Scoring.label_for(56) == :watchful
    end

    test ":constrained is 38–55" do
      assert Scoring.label_for(55) == :constrained
      assert Scoring.label_for(38) == :constrained
    end

    test ":strained is 0–37" do
      assert Scoring.label_for(37) == :strained
      assert Scoring.label_for(0) == :strained
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # pressure_score/2
  # ──────────────────────────────────────────────────────────────────────────────

  describe "pressure_score/2" do
    test "returns 100 for fully clean inputs" do
      assert Scoring.pressure_score(0, 0) == 100
    end

    test "caps at 25 when airspace = 3 and calculated score would exceed 25" do
      # airspace=3, operational=0: raw=2.1, score=30 → capped at 25
      assert Scoring.pressure_score(3, 0) == 25
    end

    test "airspace=3 cap does not prevent scores below 25" do
      # airspace=3, operational=3: raw=3.0, score=0 → stays at 0
      assert Scoring.pressure_score(3, 3) == 0
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # structural_score/3
  # ──────────────────────────────────────────────────────────────────────────────

  describe "structural_score/3" do
    test "returns 100 for all-zero (best) inputs" do
      assert Scoring.structural_score(0, 0, 0) == 100
    end

    test "returns 0 for all-3 (worst) inputs" do
      assert Scoring.structural_score(3, 3, 3) == 0
    end

    test "applies correct weights: corridor=45%, hub=35%, complexity=20%" do
      # corridor=3 only: raw = 3*0.45 = 1.35; score = 100 - round(1.35/3*100) = 100 - 45 = 55
      score_corridor = Scoring.structural_score(3, 0, 0)
      # hub=3 only: raw = 3*0.35 = 1.05; score = 100 - round(1.05/3*100) = 100 - 35 = 65
      score_hub = Scoring.structural_score(0, 3, 0)
      # complexity=3 only: raw = 3*0.20 = 0.60; score = 100 - round(0.60/3*100) = 100 - 20 = 80
      score_complexity = Scoring.structural_score(0, 0, 3)

      # Corridor (45%) hurts more than hub (35%), which hurts more than complexity (20%)
      assert score_corridor < score_hub
      assert score_hub < score_complexity
    end
  end
end
