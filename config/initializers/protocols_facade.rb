# Façade. ÚNICO lugar que liga o motor puro (ADR-0013) ao storage (ADR-0016).
# O motor não importa AR; quem precisa de um Protocol carregado vem aqui.
#
# Mora num initializer (e não em app/protocols/protocols.rb) porque
# app/protocols/ é namespace de Protocols via Zeitwerk push_dir — um arquivo
# com o mesmo nome do namespace causaria conflito.
Rails.application.config.to_prepare do
  module Protocols
    class NotFound < StandardError; end

    class << self
      # Versão ativa para um par (municipality_id, name). Override por município ganha.
      def current(municipality_id, name: "triage-respiratoria")
        Rails.cache.fetch(current_cache_key(name, municipality_id)) do
          record = ProtocolDefinition
            .where(name: name, status: "active")
            .where(municipality_id: [municipality_id, nil])
            .order(Arel.sql("municipality_id NULLS LAST"))
            .first
          raise NotFound, "no active definition for #{name}" unless record
          Definitions.build(record.definition)
        end
      end

      # Versão exata. Usado por relatórios históricos (ADR-0007 / ADR-0016).
      def fetch(name:, version:, municipality_id: nil)
        record = ProtocolDefinition.find_by(
          name: name,
          version: version,
          municipality_id: municipality_id
        )
        raise NotFound, "definition #{name}@#{version} not found" unless record
        Definitions.build(record.definition)
      end

      # Invalidate every cached resolution for `name` across municipalities.
      # SolidCache (dev/prod) has no #delete_matched, so instead of pattern-
      # deleting keys we bump a per-name generation woven into the cache key,
      # making the old entries unreachable. Same scope as the former wildcard.
      def invalidate(name)
        key = generation_key(name)
        Rails.cache.write(key, Rails.cache.read(key).to_i + 1)
      end

      private

      def current_cache_key(name, municipality_id)
        generation = Rails.cache.read(generation_key(name)).to_i
        ["protocols.current", generation, name, municipality_id].join("/")
      end

      def generation_key(name)
        ["protocols.generation", name].join("/")
      end
    end
  end
end
