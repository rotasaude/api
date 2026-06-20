# Fábrica de scoring. Ver ADR-0017.
module Protocols
  module Scoring
    UnknownStrategy = Class.new(StandardError)

    def self.build(hash)
      return nil if hash.nil?
      case hash["type"]
      when "weighted"
        Weighted.new(
          thresholds: hash.fetch("thresholds"),
          priority_map: hash.fetch("priority_map", {})
        )
      when "decision_table"
        DecisionTable.new(
          rules: hash.fetch("rules"),
          fallback: hash.fetch("fallback", { tier: "indefinido", priority: 9 }).transform_keys(&:to_sym)
        )
      else
        raise UnknownStrategy, "scoring.type=#{hash["type"].inspect}"
      end
    end
  end
end
