# Pedido de agendamento gerado pela triagem (ADR 0029 §5.2). Roda dentro da
# transação do CompleteTriage, depois de complete! e de Triages::Suggest. Nada
# se o resultado é urgente ou se a conversa não tem cidadão (WhatsApp): o
# início é o mesmo da sugestão (Triages::Conclusion). Vale a PRIMEIRA regra de
# scheduling[] cujo `when` é verdadeiro (perfil + respostas + resultado).
# Unidade = a primeira de referência do bairro copiado na triagem; sem ela,
# fila "sem unidade" (target_unit nulo). Tipo inexistente ou inativo na cidade
# não impede o pedido: nasce com a key (contratos §10). Havendo pedido vivo
# (aberto OU marcado) do mesmo tipo para o cidadão, funde: prazo menor,
# prioridade maior, triagem ligada em appointment_request_triages. O índice
# único parcial (triagem viva por cidadão e tipo) fecha a corrida entre duas
# conclusões: o insert perdedor cai na fusão (savepoint).
module Triages
  module Schedule
    module_function

    def call(triage:, outcome:, on: Time.zone.today)
      found = Conclusion.rules_for(triage: triage, outcome: outcome, key: "scheduling", on: on)
      return nil unless found

      rule = found.rules.find { |r| r.is_a?(Hash) && Protocols::Condition.eval(r["when"], found.context) }
      return nil unless rule

      attrs = { key: rule["appointment_type"].to_s,
                priority: AppointmentRequest::PRIORITIES.include?(rule["priority"]) ? rule["priority"] : "routine",
                due_on: on + rule["due_in_days"].to_i.clamp(1, 365) }
      merge(found.citizen, triage, attrs) || create(found.citizen, triage, attrs)
    end

    def merge(citizen, triage, attrs)
      request = AppointmentRequest.live_requests.where(citizen_id: citizen.id, appointment_type_key: attrs[:key])
                                  .order(:created_at).lock.first
      return nil unless request

      priority = [ request.priority, attrs[:priority] ].include?("priority") ? "priority" : "routine"
      request.update!(due_on: [ request.due_on, attrs[:due_on] ].min, priority: priority)
      AppointmentRequestTriage.create!(request: request, triage: triage, created_at: Time.current)
      DomainEvents.publish("appointment_request.merged_triage", request_id: request.id, triage_id: triage.id)
      request
    end

    def create(citizen, triage, attrs)
      unit = Territory::ReferenceUnits.for(triage.neighborhood_id).first
      request = ApplicationRecord.transaction(requires_new: true) do
        AppointmentRequest.create!(kind: "triage", origin_triage: triage, root_triage: triage, citizen: citizen,
                                   target_unit: unit, appointment_type_key: attrs[:key], priority: attrs[:priority],
                                   due_on: attrs[:due_on])
      end
      DomainEvents.publish("appointment_request.created_from_triage", request_id: request.id, triage_id: triage.id)
      request
    rescue ActiveRecord::RecordNotUnique
      merge(citizen, triage, attrs)
    end
  end
end
