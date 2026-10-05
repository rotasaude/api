# Catálogo do cidadão (ADR 0027; spec 2026-10-05 §5.3, §6.1; contratos §3.4).
# Um protocolo aparece em `suggested` OU em `available`, nunca nos dois; o que
# está em andamento só aparece em `in_progress` (desvio 6 do plano). A leitura
# EXPIRA toda sugestão pendente do par cujo protocolo deixou de estar
# `available` (expiração preguiçosa) e soma 1 na contagem diária de cada
# protocolo mostrado em oferta (desvio 1). `reference_units` vem do bairro
# ATUAL do par (módulo 11), [] sem bairro.
module Triages
  module Catalog
    module_function

    def for(citizen:, on: Time.zone.today)
      items = Offer.for(citizen: citizen, on: on)
      available = items.select(&:available?)
      in_progress = in_progress_triage(citizen)
      expire_stale!(citizen, available.map(&:protocol_name))

      pending = TriageSuggestion.status_pending.where(citizen_id: citizen.id)
                                .includes(source_triage: :protocol_definition).index_by(&:protocol_name)
      shown = available.reject { |item| item.protocol_name == in_progress&.protocol_name }
      suggested, offered = shown.partition { |item| pending.key?(item.protocol_name) }
      TriageOfferDailyCount.increment!(shown.map(&:protocol_name), day: on)

      {
        in_progress: in_progress && in_progress_json(in_progress),
        suggested: suggested.map { |item| suggested_json(item, pending.fetch(item.protocol_name)) },
        available: offered.map { |item| item_json(item) },
        recent: items.select(&:recent?).map { |item| recent_json(item) },
        reference_units: Territory::ReferenceUnits.as_json_list(Territory::ReferenceUnits.for(citizen.neighborhood_id))
      }
    end

    def in_progress_triage(citizen)
      Triage.status_in_progress.joins(:conversation)
            .where(conversations: { channel: "web", citizen_id: citizen.id, state: Conversation::ACTIVE_STATES })
            .includes(:protocol_definition).order(created_at: :desc).first
    end

    def expire_stale!(citizen, available_names)
      TriageSuggestion.status_pending.where(citizen_id: citizen.id).where.not(protocol_name: available_names)
                      .update_all(status: "expired", resolved_at: Time.current)
    end

    def item_json(item) = { protocol_name: item.protocol_name, title: item.title, summary: item.summary }

    def recent_json(item)
      item_json(item).merge(last_completed_on: item.last_completed_on.iso8601,
                            next_available_on: item.next_available_on.iso8601)
    end

    def suggested_json(item, suggestion)
      source = suggestion.source_triage
      item_json(item).merge(
        suggestion_id: suggestion.id, source_triage_id: suggestion.source_triage_id,
        source_title: Offer.title_for(source.protocol_definition.definition, source.protocol_name),
        suggested_on: suggestion.created_at.in_time_zone.to_date.iso8601
      )
    end

    def in_progress_json(triage)
      { conversation_id: triage.conversation_id, protocol_name: triage.protocol_name,
        title: Offer.title_for(triage.protocol_definition.definition, triage.protocol_name) }
    end
  end
end
