# Sugestões na conclusão (ADR 0027; spec 2026-10-05 §5.3). Roda dentro da
# transação do CompleteTriage, depois de complete!. Nada se o resultado é
# urgente (Protocols::Urgency) ou se a conversa não tem cidadão (WhatsApp).
# Cada suggestions[] da versão EXATA da triagem cujo `when` é verdadeiro
# (perfil + respostas + resultado) e cujo protocolo está `available` para o par
# vira uma linha pending. Já havendo pendente daquele protocolo para o par, o
# índice único parcial recusa e a sugestão é ignorada (savepoint: a transação
# da conclusão segue). Não trava o cidadão por conta própria: SubmitAnswer já
# travou cidadão → conversa antes (desvio 5 do plano), então o FOR KEY SHARE da
# FK de triage_suggestions não inverte a ordem.
module Triages
  module Suggest
    module_function

    def call(triage:, outcome:, on: Time.zone.today)
      found = Conclusion.rules_for(triage: triage, outcome: outcome, key: "suggestions", on: on)
      return [] unless found

      citizen = found.citizen
      available = Offer.for(citizen: citizen, on: on).select(&:available?).map(&:protocol_name)
      found.rules.filter_map do |rule|
        next unless rule.is_a?(Hash)

        name = rule["protocol"].to_s
        next if name == triage.protocol_name || !available.include?(name)
        next unless Protocols::Condition.eval(rule["when"], found.context)

        create_pending(citizen, triage, name)
      end
    end

    def create_pending(citizen, triage, name)
      suggestion = ApplicationRecord.transaction(requires_new: true) do
        TriageSuggestion.create!(citizen: citizen, source_triage: triage, protocol_name: name)
      end
      DomainEvents.publish("triage.suggested", triage_id: triage.id, suggestion_id: suggestion.id, protocol_name: name)
      suggestion
    rescue ActiveRecord::RecordNotUnique
      nil
    end
  end
end
