# O catálogo como a aba do dashboard o mostra (contratos §4.1): um item por
# protocolo com versão active; `configured: false` = sem linha em
# triage_offers. Elegibilidade e intervalo vêm da versão ativa (assinada).
module Triages
  module CatalogAdmin
    module_function

    def index
      actives = ProtocolDefinition.active.to_a
      names = actives.map(&:name)
      rows = TriageOffer.where(protocol_name: names).index_by(&:protocol_name)
      counters = Counters.for(names)
      items = actives.map { |definition| item(definition.name, definition, rows[definition.name], counters[definition.name]) }
      items.sort_by { |i| [ i[:configured] ? 0 : 1, i[:position] || 0, i[:title] ] }
    end

    def item_for(protocol_name)
      name = protocol_name.to_s
      item(name, ProtocolDefinition.active.find_by(name: name), TriageOffer.find_by(protocol_name: name),
           Counters.for([ name ]).fetch(name))
    end

    def item(name, definition, row, counters)
      offer = definition && definition.definition["offer"].is_a?(Hash) ? definition.definition["offer"] : {}
      {
        protocol_name: name, title: Offer.title_for(definition&.definition, name), active_version: definition&.version,
        eligibility: offer["eligibility"], retake_after_days: offer["retake_after_days"], configured: !row.nil?,
        enabled: row&.enabled, position: row&.position, restriction: row&.restriction,
        available_from: row&.available_from&.iso8601, available_until: row&.available_until&.iso8601,
        counters: counters
      }
    end
  end
end
