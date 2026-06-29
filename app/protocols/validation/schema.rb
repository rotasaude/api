# Full JSON Schema (draft 2020-12) validation against the vendored contract.
# The schema file mirrors packages/protocols/schema.json (ADR-0016).
module Protocols
  module Validation
    module Schema
      PATH = Rails.root.join("config/protocols/schema.json")

      def self.call(definition)
        schemer.validate(definition || {}).map do |error|
          pointer = error["data_pointer"].presence || "(root)"
          "schema: #{pointer} #{error["type"]}"
        end
      end

      def self.schemer
        @schemer ||= JSONSchemer.schema(JSON.parse(File.read(PATH)))
      end
    end
  end
end
