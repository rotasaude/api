# Scoring por tabela de decisão: primeira regra que casa ganha. Ver ADR-0017.
module Protocols
  module Scoring
    class DecisionTable
      attr_reader :rules, :fallback

      # rules: [{ when: { step_id => answer, ... }, tier:, priority: }]
      # fallback: { tier:, priority: }   -- aplicado quando nenhuma regra casa
      def initialize(rules:, fallback: { tier: "indefinido", priority: 9 })
        @rules = rules
        @fallback = fallback
        freeze
      end

      def call(trail)
        answers = trail.to_h { |entry| [entry[:step].to_s, entry[:answer].to_s] }

        match = rules.find { |rule| matches?(rule[:when] || rule["when"], answers) }
        if match
          Outcome.terminal(
            trail: trail,
            tier: (match[:tier] || match["tier"]).to_s,
            priority: (match[:priority] || match["priority"]).to_i
          )
        else
          Outcome.terminal(
            trail: trail,
            tier: fallback[:tier].to_s,
            priority: fallback[:priority].to_i
          )
        end
      end

      def to_h
        {
          "type" => "decision_table",
          "rules" => rules,
          "fallback" => fallback
        }
      end

      private

      def matches?(conditions, answers)
        conditions.all? { |step_id, expected| answers[step_id.to_s] == expected.to_s }
      end
    end
  end
end
