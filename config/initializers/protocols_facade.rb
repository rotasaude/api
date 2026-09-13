# Façade. ÚNICO lugar que liga o motor puro ao storage (ADR-0009).
# O motor não importa AR; quem precisa de um Protocol carregado vem aqui.
#
# Mora num initializer (e não em app/protocols/protocols.rb) porque
# app/protocols/ é namespace de Protocols via Zeitwerk push_dir — um arquivo
# com o mesmo nome do namespace causaria conflito.
Rails.application.config.to_prepare do
  module Protocols
    class NotFound < StandardError; end

    class << self
      # Versão ativa de `name` na cidade da conexão corrente. O banco inteiro é
      # da cidade: não existe mais override por município nem versão global.
      def current(name: "triage-respiratoria")
        Rails.cache.fetch(current_cache_key(name)) do
          record = ProtocolDefinition.find_by(name: name, status: "active")
          raise NotFound, "no active definition for #{name}" unless record
          Definitions.build(record.definition)
        end
      end

      # Versão exata. Usado por relatórios históricos (ADR-0010 / ADR-0009).
      def fetch(name:, version:)
        record = ProtocolDefinition.find_by(name: name, version: version)
        raise NotFound, "definition #{name}@#{version} not found" unless record
        Definitions.build(record.definition)
      end

      # Invalidate every cached resolution for `name` in the current city.
      # SolidCache (dev/prod) has no #delete_matched, so instead of pattern-
      # deleting keys we bump a per-(city, name) generation woven into the
      # cache key, making the old entries unreachable.
      def invalidate(name)
        key = generation_key(name)
        Rails.cache.write(key, Rails.cache.read(key).to_i + 1)
      end

      private

      # O cache ainda vive fora do banco da cidade (Solid Cache compartilhado
      # até o Plano 5): a chave PRECISA carregar a cidade, senão o protocolo
      # ativo de uma cidade seria servido a outra. Usa o shard da conexão —
      # a mesma fonte de onde a query lê —, não Current.city.
      def city_cache_scope
        CityRecord.current_shard
      end

      def current_cache_key(name)
        generation = Rails.cache.read(generation_key(name)).to_i
        ["protocols.current", city_cache_scope, generation, name].join("/")
      end

      def generation_key(name)
        ["protocols.generation", city_cache_scope, name].join("/")
      end
    end
  end
end
