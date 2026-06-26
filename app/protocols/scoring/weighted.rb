# Scoring por soma de pesos com thresholds. Módulo puro — ver ADR-0017.
module Protocols
  module Scoring
    class Weighted
      attr_reader :thresholds, :priority_map

      # thresholds: { "baixa" => 0, "media" => 4, "alta" => 8 }  (limite inferior por tier)
      # priority_map: { "baixa" => 9, "media" => 5, "alta" => 1 }
      def initialize(thresholds:, priority_map: {})
        @thresholds = thresholds.sort_by { |_, v| -v }   # do maior pro menor
        @priority_map = priority_map
        freeze
      end

      def call(trail)
        # O peso de cada resposta vem do próprio Step (step.weights[answer]).
        score = trail.sum { |entry| entry[:weight].to_i }
        tier = pick_tier(score)
        Outcome.terminal(
          trail: trail,
          tier: tier,
          priority: priority_map.fetch(tier, 5),
          score: score
        )
      end

      def to_h
        {
          "type" => "weighted",
          "thresholds" => thresholds.to_h,
          "priority_map" => priority_map
        }
      end

      private

      def pick_tier(score)
        match = thresholds.find { |_, threshold| score >= threshold }
        match ? match.first : thresholds.last&.first
      end
    end
  end
end
