# Base de tipos da plataforma e catálogo da cidade (ADR 0029 §3.1). A base vem
# de config/scheduling/appointment_types.yml; a migração 20261006100001 e o
# provisionamento a copiam só inserindo o que falta.
module Scheduling
  module AppointmentTypes
    PATH = Rails.root.join("config/scheduling/appointment_types.yml")

    class Catalog
      def initialize(records)
        @records = records
        @by_key = records.index_by(&:key)
      end

      def find(key) = @by_key[key.to_s]

      def name_for(key)
        return nil if key.nil?

        find(key)&.name || key.to_s
      end

      def active = @records.select(&:active).to_h { |r| [ r.key, data(r) ] }

      def fallback = @records.select { |r| r.active && r.platform? }.sort_by(&:position).map { |r| data(r) }

      private

      def data(record)
        Availability::Type.new(key: record.key, duration_minutes: record.duration_minutes,
                               cbo_prefixes: Array(record.cbo_prefixes))
      end
    end

    module_function

    def base = @base ||= YAML.load_file(PATH).map(&:freeze).freeze

    def seed_platform!(now: Time.current)
      rows = base.each_with_index.map do |type, index|
        { key: type.fetch("key"), name: type.fetch("name"), duration_minutes: type.fetch("duration_minutes"),
          cbo_prefixes: type.fetch("cbo_prefixes").map(&:to_s), active: true, origin: "platform",
          position: index + 1, created_at: now, updated_at: now }
      end
      AppointmentType.insert_all(rows, unique_by: :key).rows.size
    end

    def serves?(type, cbo_code) = Array(type.cbo_prefixes).any? { |prefix| cbo_code.to_s.start_with?(prefix) }

    def catalog = Catalog.new(AppointmentType.listed.to_a)
  end
end
