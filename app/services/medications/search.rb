# app/services/medications/search.rb
# Busca no catálogo da plataforma (ADR 0033; contrato §5): todos os termos
# (sem acento, maiúsculos) no texto de busca; só itens ativos e não
# escondidos; os da REMUME da cidade primeiro ("na rede": REMUME sem
# unidades = toda a rede; com unidades, só nelas). Catálogo ou listas Anvisa
# ausentes → Unavailable (sem as listas, controlado não seria bloqueado).
module Medications
  module Search
    LIMIT = 30
    MIN_QUERY = 2
    class Unavailable < StandardError; end

    module_function

    def available? = MedicationCatalogRelease.current.present? && AnvisaListRelease.current.present?

    def call(q:, unit_id: nil)
      raise Unavailable unless available?

      tokens = Substances.key(q).split.first(6)
      return [] if tokens.join.size < MIN_QUERY

      scope = tokens.reduce(MedicationCatalogItem.prescribable) do |relation, token|
        relation.where("search_text LIKE ?", "%#{MedicationCatalogItem.sanitize_sql_like(token)}%")
      end
      network = network_ids(unit_id)
      ordered = ->(relation) { relation.order(:active_ingredient, :strength, :catmat_code) }
      inside = network.empty? ? [] : ordered.(scope.where(id: network.to_a)).limit(LIMIT).to_a
      outside = ordered.(scope.where.not(id: inside.map(&:id))).limit(LIMIT - inside.size).to_a
      inside.map { |item| ClinicalDocuments::Json.catalog_item(item, in_network: true) } +
        outside.map { |item| ClinicalDocuments::Json.catalog_item(item, in_network: false) }
    end

    def network_ids(unit_id)
      CityMedication.pluck(:catalog_item_id, :unit_ids)
                    .select { |_id, units| units.empty? || unit_id.nil? || units.include?(unit_id) }
                    .to_set(&:first)
    end
    private_class_method :network_ids
  end
end
