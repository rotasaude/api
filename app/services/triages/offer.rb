# app/services/triages/offer.rb
# Regra de oferta (ADR 0027; spec 2026-10-05 §5.1). Um protocolo com versão
# active está em oferta para o par quando:
#   1. sem linha no catálogo: só se não tiver offer.eligibility (o de hoje);
#      com linha: enabled e dentro de available_from..available_until;
#   2. offer.eligibility verdadeira no contexto do par;
#   3. restriction verdadeira (ausente = verdadeira) — soma com E, nunca amplia;
#   4. intervalo: recent enquanto hoje < última conclusão + retake_after_days.
# `suggestion_only` (linha da cidade) não muda a oferta: a sugestão nasce e
# fica pendente. Só tira de "Disponíveis" (Catalog) e exige a sugestão para
# começar (startable?).
# `evaluate` é PURA (dados já carregados, data por argumento) e testável em
# tabela; `for` só carrega do banco da cidade e chama.
module Triages
  module Offer
    Row = Data.define(:enabled, :position, :restriction, :available_from, :available_until, :suggestion_only) do
      def initialize(suggestion_only: false, **rest) = super
    end
    Item = Data.define(:protocol_name, :title, :summary, :state, :position, :last_completed_on, :next_available_on,
                       :suggestion_only) do
      def available? = state == "available"
      def recent? = state == "recent"
    end

    module_function

    def evaluate(protocols:, rows:, context:, last_completed:, on:)
      items = protocols.filter_map do |protocol|
        name = protocol.fetch(:name)
        offer = protocol[:offer].is_a?(Hash) ? protocol[:offer] : {}
        row = rows[name]
        next unless listed?(row, offer, on)
        next unless offer["eligibility"].nil? || Protocols::Condition.eval(offer["eligibility"], context)
        next unless row.nil? || row.restriction.nil? || Protocols::Condition.eval(row.restriction, context)

        item(name, offer, row, last_completed[name], on)
      end
      items.sort_by { |i| [ i.position.nil? ? 1 : 0, i.position || 0, i.title ] }
    end

    def listed?(row, offer, on)
      return offer["eligibility"].nil? if row.nil?

      row.enabled && (row.available_from.nil? || row.available_from <= on) &&
        (row.available_until.nil? || on <= row.available_until)
    end

    def item(name, offer, row, last_on, on)
      days = offer["retake_after_days"]
      next_on = last_on && days.is_a?(Integer) && days.positive? ? last_on + days : nil
      recent = next_on.present? && on < next_on
      Item.new(protocol_name: name, title: offer["title"].presence || name, summary: offer["summary"].presence,
               state: recent ? "recent" : "available", position: row&.position, last_completed_on: last_on,
               next_available_on: recent ? next_on : nil, suggestion_only: row&.suggestion_only || false)
    end

    def title_for(definition, name)
      offer = definition.is_a?(Hash) && definition["offer"].is_a?(Hash) ? definition["offer"] : {}
      offer["title"].presence || name
    end

    def for(citizen:, on: Time.zone.today)
      protocols = ProtocolDefinition.triage_protocols.active.pluck(:name, :definition).map do |name, definition|
        { name: name, offer: definition.is_a?(Hash) ? definition["offer"] : nil }
      end
      rows = TriageOffer.all.to_h do |r|
        [ r.protocol_name, Row.new(enabled: r.enabled, position: r.position, restriction: r.restriction,
                                   available_from: r.available_from, available_until: r.available_until,
                                   suggestion_only: r.suggestion_only) ]
      end
      context = Protocols::ConditionContext.build(profile: citizen.profile_context(on: on),
                                                  citizen: { neighborhood_id: citizen.neighborhood_id })
      evaluate(protocols: protocols, rows: rows, context: context, last_completed: last_completed(citizen), on: on)
    end

    def available?(citizen:, protocol_name:, on: Time.zone.today)
      self.for(citizen: citizen, on: on).any? { |i| i.protocol_name == protocol_name.to_s && i.available? }
    end

    # Pode começar agora: em oferta e, se só por sugestão, com uma pendente do par.
    def startable?(citizen:, protocol_name:, on: Time.zone.today)
      item = self.for(citizen: citizen, on: on).find { |i| i.protocol_name == protocol_name.to_s && i.available? }
      return false unless item
      return true unless item.suggestion_only

      TriageSuggestion.status_pending.exists?(citizen_id: citizen.id, protocol_name: item.protocol_name)
    end

    # Data local (fuso da cidade) do created_at da última conclusão do PAR.
    # Só conclusão que conta (Triage.counted_completed): triagem com o
    # consentimento revogado não segura o protocolo em `recent`.
    def last_completed(citizen)
      Triage.joins(:conversation).where(conversations: { citizen_id: citizen.id }).counted_completed
            .group(:protocol_name).maximum(:created_at)
            .transform_values { |at| at.in_time_zone.to_date }
    end
  end
end
