# Semantic graph checks beyond JSON Schema and beyond Validator's refs/cycles:
# step reachability from start_step_id, and branches/weights key validity per
# answer_type.
module Protocols
  module Validation
    module Graph
      def self.call(definition)
        steps = definition["steps"] || []
        unreachable_errors(definition["start_step_id"], steps) + key_validity_errors(steps)
      end

      def self.unreachable_errors(start_id, steps)
        reachable = reachable_ids(start_id, steps)
        steps.map { |s| s["id"] }
             .reject { |id| reachable.include?(id) }
             .map { |id| "unreachable step: #{id}" }
      end

      def self.reachable_ids(start_id, steps)
        by_id = steps.to_h { |s| [s["id"], s] }
        seen = Set.new
        queue = [start_id].compact
        until queue.empty?
          id = queue.shift
          next if seen.include?(id)
          seen << id
          step = by_id[id]
          next unless step
          (step["branches"] || {}).values.compact.each { |nxt| queue << nxt }
        end
        seen
      end

      def self.key_validity_errors(steps)
        steps.flat_map do |step|
          allowed = Answers.for(step)
          next [] if allowed.nil?
          { "branches" => "branch", "weights" => "weight" }.flat_map do |field, label|
            (step[field] || {}).keys.reject { |k| allowed.include?(k.to_s) }
              .map { |k| "#{label} key '#{k}' invalid for #{step["answer_type"]} step #{step["id"]}" }
          end
        end
      end
    end
  end
end
