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
      def current(municipality_id, name: "triagem-respiratoria")
        cache_key = ["protocols.current", name, municipality_id].join("/")
        Rails.cache.fetch(cache_key) do
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
    end
  end
end
