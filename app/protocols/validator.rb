# Valida uma definição de protocolo. Módulo puro — ver ADR-0013 e ADR-0016.
# Combina JSON Schema (forma) com linter (semântica: referências, ciclos, ramos órfãos).
module Protocols
  class Validator
    Result = Struct.new(:valid?, :errors, keyword_init: true) do
      def initialize(valid: nil, errors: [])
        super(valid?: valid.nil? ? errors.empty? : valid, errors: errors)
      end
    end

    def self.call(definition_hash)
      new(definition_hash).call
    end

    def initialize(definition_hash)
      @definition = definition_hash || {}
    end

    def call
      errors = []
      errors.concat(schema_errors)
      errors.concat(linter_errors) if errors.empty?
      Result.new(errors: errors)
    end

    private

    attr_reader :definition

    def schema_errors
      # JSON Schema real fica em packages/protocols/schema.json (ADR-0016).
      # Aqui validamos as obrigações mínimas para evitar acoplamento ao JSON
      # Schema runtime durante o boot — o lint completo roda no script offline.
      errors = []
      errors << "missing :name" unless definition["name"].is_a?(String)
      errors << "missing :version" unless definition["version"].is_a?(Integer)
      errors << "missing :start_step_id" unless definition["start_step_id"].is_a?(String)
      errors << "missing :steps" unless definition["steps"].is_a?(Array)
      errors
    end

    def linter_errors
      errors = []
      step_ids = definition["steps"].map { |s| s["id"] }.to_set
      errors << "start_step_id refers to unknown step" unless step_ids.include?(definition["start_step_id"])

      definition["steps"].each do |s|
        (s["branches"] || {}).each_value do |next_id|
          next if next_id.nil?
          errors << "step #{s["id"]} branches to unknown step #{next_id}" unless step_ids.include?(next_id)
        end
      end

      errors << "graph has a cycle" if cycle?(definition["steps"])
      errors.concat(recommendation_errors)
      errors
    end

    def recommendation_errors
      recs = definition["recommendations"]
      return [] unless recs.is_a?(Hash)
      tiers = declared_tiers
      recs.keys.reject { |k| tiers.include?(k) }.map { |k| "recommendation for unknown tier #{k}" }
    end

    def declared_tiers
      scoring = definition["scoring"]
      return Set.new unless scoring.is_a?(Hash)
      case scoring["type"]
      when "weighted"
        (scoring["thresholds"] || {}).keys.to_set
      when "decision_table"
        tiers = Array(scoring["rules"]).map { |r| r["tier"] }
        tiers << scoring.dig("fallback", "tier")
        tiers.compact.to_set
      else
        Set.new
      end
    end

    def cycle?(steps)
      adj = steps.to_h { |s| [s["id"], (s["branches"] || {}).values.compact] }
      visited = Set.new
      stack = Set.new
      walk = ->(node) {
        return false if visited.include?(node)
        visited << node
        stack << node
        adj.fetch(node, []).each do |nxt|
          return true if stack.include?(nxt)
          return true if walk.call(nxt)
        end
        stack.delete(node)
        false
      }
      adj.keys.any?(&walk)
    end
  end
end
