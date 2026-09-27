# Scoring por tabela de decisão: primeira regra que casa ganha. Ver ADR-0009.
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

        index = rules.find_index { |rule| matches?(rule[:when] || rule["when"], answers) }
        match = index && rules[index]
        tier, priority, ref =
          if match
            [(match[:tier] || match["tier"]).to_s, (match[:priority] || match["priority"]).to_i, "rule:#{index}"]
          else
            [fallback[:tier].to_s, fallback[:priority].to_i, "fallback"]
          end

        Outcome.terminal(
          trail: trail,
          tier: tier,
          priority: priority,
          explanation: [
            { ev: "rule_matched", rule: "decision_table", ref: ref, out: tier },
            { ev: "tier_assigned", rule: "decision_table", ref: ref, out: tier }
          ]
        )
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
        Protocols::Condition.eval(conditions, answers)
      end
    end
  end
end
