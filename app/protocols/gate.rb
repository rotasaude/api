# Full publish/preview quality gate for a protocol definition (F-03.9).
# Composes the JSON Schema check, the graph and scoring semantic linters, and
# reuses Protocols::Validator (refs/cycles/recommendation). Returns a
# Protocols::Validator::Result. If the shape (schema) is invalid, semantic
# checks are skipped — they assume a valid shape.
module Protocols
  module Gate
    def self.call(definition)
      definition ||= {}

      schema_errors = Validation::Schema.call(definition)
      return Validator::Result.new(errors: schema_errors) if schema_errors.any?

      errors = []
      errors.concat(Validator.call(definition).errors)   # refs, cycles, recommendation↔tier
      errors.concat(Validation::Graph.call(definition))
      errors.concat(Validation::Scoring.call(definition))
      Validator::Result.new(errors: errors)
    end
  end
end
