# Valid answer values for a step, shared by the graph and scoring linters.
module Protocols
  module Validation
    module Answers
      BOOLEAN = %w[true false].freeze

      # Returns the allowed answer strings for a step, or nil when the answer
      # space is unconstrained (integer/text) and key validation does not apply.
      def self.for(step)
        case step["answer_type"]
        when "boolean" then BOOLEAN
        when "enum" then Array(step["options"]).map(&:to_s)
        end
      end
    end
  end
end
