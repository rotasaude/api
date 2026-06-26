# Fábrica Hash -> Protocol. Módulo puro — ver ADR-0013.
# A leitura do storage (banco / arquivo) acontece em Protocols.fetch (ADR-0016),
# que vive em protocols.rb e NÃO faz parte do motor puro.
module Protocols
  module Definitions
    InvalidDefinition = Class.new(StandardError)

    def self.build(hash)
      result = Validator.call(hash)
      raise InvalidDefinition, result.errors.join("; ") unless result.valid?

      steps = hash["steps"].map do |s|
        Step.new(
          id: s["id"],
          prompt: s["prompt"],
          answer_type: s["answer_type"],
          options: s["options"],
          branches: s["branches"] || {},
          weights: s["weights"] || {}
        )
      end

      Protocol.new(
        name: hash["name"],
        version: hash["version"],
        steps: steps,
        start_step_id: hash["start_step_id"],
        scoring: Scoring.build(hash["scoring"])
      )
    end
  end
end
